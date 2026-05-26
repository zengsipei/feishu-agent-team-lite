import asyncio
import json
import logging
import os
import signal
import sys
from datetime import UTC, datetime

from .adapter import ChannelAdapter
from .config import Settings, get_settings
from .registry import AgentApp, AgentAppRegistry

logger = logging.getLogger(__name__)


def configure_logging(level: str) -> None:
    logging.basicConfig(
        level=getattr(logging, level.upper(), logging.INFO),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )


def list_enabled_apps(settings: Settings) -> list[AgentApp]:
    registry = AgentAppRegistry(settings.agent_runtime_config_path)
    return registry.list_apps(
        enabled_app_ids=settings.enabled_app_id_set,
        enabled_agent_ids=settings.enabled_agent_id_set,
    )


def install_stop_signal(stop_event: asyncio.Event) -> None:
    loop = asyncio.get_running_loop()

    def request_stop() -> None:
        stop_event.set()

    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, request_stop)
        except NotImplementedError:
            pass


def write_worker_status(settings: Settings, app: AgentApp, status: str, *, message: str = "", pid: int | None = None) -> None:
    settings.adapter_status_dir.mkdir(parents=True, exist_ok=True)
    payload = {
        "agent_id": app.agent_id,
        "agent_name": app.agent_name,
        "app_id": app.app_id,
        "pid": pid or os.getpid(),
        "status": status,
        "message": message,
        "updated_at": datetime.now(UTC).isoformat(),
    }
    target = settings.adapter_status_dir / f"{app.agent_id}.json"
    temp = settings.adapter_status_dir / f"{app.agent_id}.tmp"
    temp.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    temp.replace(target)


def clear_worker_statuses(settings: Settings, apps: list[AgentApp]) -> None:
    settings.adapter_status_dir.mkdir(parents=True, exist_ok=True)
    for app in apps:
        for suffix in ("json", "tmp"):
            path = settings.adapter_status_dir / f"{app.agent_id}.{suffix}"
            try:
                path.unlink()
            except FileNotFoundError:
                pass


async def run_worker(settings: Settings) -> None:
    if not settings.worker_agent_id:
        raise RuntimeError("WORKER_AGENT_ID is required in worker mode")

    registry = AgentAppRegistry(settings.agent_runtime_config_path)
    apps = registry.list_apps(
        enabled_app_ids=settings.enabled_app_id_set,
        enabled_agent_ids={settings.worker_agent_id},
    )
    if len(apps) != 1:
        raise RuntimeError(f"Expected exactly one app for worker agent {settings.worker_agent_id}, got {len(apps)}")

    app = apps[0]
    worker_status = "stopped"
    write_worker_status(settings, app, "starting")
    adapter = ChannelAdapter(settings=settings, apps=apps)
    install_stop_signal(adapter._stop_event)
    try:
        await adapter.start()
        worker_status = "connected"
        write_worker_status(settings, app, worker_status)
        await adapter._stop_event.wait()
    except Exception as exc:
        worker_status = "error"
        write_worker_status(settings, app, worker_status, message=type(exc).__name__)
        raise
    finally:
        if worker_status != "error":
            write_worker_status(settings, app, "stopped")
        await adapter.stop()


async def start_worker(app: AgentApp) -> asyncio.subprocess.Process:
    env = os.environ.copy()
    env["WORKER_AGENT_ID"] = app.agent_id
    logger.info("Starting Feishu Channel worker agent_id=%s app_id=%s", app.agent_id, app.app_id)
    return await asyncio.create_subprocess_exec(sys.executable, "-m", "app.main", env=env)


async def stop_workers(processes: dict[str, tuple[AgentApp, asyncio.subprocess.Process, asyncio.Task[int]]]) -> None:
    for app, process, _ in processes.values():
        if process.returncode is None:
            logger.info("Stopping Feishu Channel worker agent_id=%s pid=%s", app.agent_id, process.pid)
            process.terminate()

    pending = [process.wait() for _, process, _ in processes.values() if process.returncode is None]
    if not pending:
        return

    try:
        await asyncio.wait_for(asyncio.gather(*pending), timeout=10)
    except asyncio.TimeoutError:
        for app, process, _ in processes.values():
            if process.returncode is None:
                logger.warning("Killing unresponsive Feishu Channel worker agent_id=%s pid=%s", app.agent_id, process.pid)
                process.kill()
        await asyncio.gather(
            *[process.wait() for _, process, _ in processes.values() if process.returncode is None],
            return_exceptions=True,
        )


async def run_supervisor(settings: Settings) -> None:
    apps = list_enabled_apps(settings)
    if not apps:
        raise RuntimeError("No apps enabled for channel adapter")

    clear_worker_statuses(settings, apps)
    logger.info("Starting Feishu Channel supervisor for %d app(s)", len(apps))
    stop_event = asyncio.Event()
    install_stop_signal(stop_event)
    stop_task = asyncio.create_task(stop_event.wait())
    processes: dict[str, tuple[AgentApp, asyncio.subprocess.Process, asyncio.Task[int]]] = {}

    try:
        for app in apps:
            process = await start_worker(app)
            processes[app.agent_id] = (app, process, asyncio.create_task(process.wait()))

        while not stop_event.is_set():
            wait_tasks = [item[2] for item in processes.values()]
            done, _ = await asyncio.wait([stop_task, *wait_tasks], return_when=asyncio.FIRST_COMPLETED)
            if stop_task in done:
                break

            for task in done:
                exited = [
                    (agent_id, app, process)
                    for agent_id, (app, process, wait_task) in processes.items()
                    if wait_task is task
                ]
                for agent_id, app, process in exited:
                    exit_code = task.result()
                    logger.warning(
                        "Feishu Channel worker exited agent_id=%s app_id=%s pid=%s exit_code=%s",
                        app.agent_id,
                        app.app_id,
                        process.pid,
                        exit_code,
                    )
                    write_worker_status(settings, app, "exited", message=f"exit_code={exit_code}", pid=process.pid)
                    processes.pop(agent_id, None)
                    if not stop_event.is_set():
                        await asyncio.sleep(5)
                        restarted = await start_worker(app)
                        processes[agent_id] = (app, restarted, asyncio.create_task(restarted.wait()))
    finally:
        stop_task.cancel()
        await stop_workers(processes)


async def main_async() -> None:
    settings = get_settings()
    configure_logging(settings.log_level)
    if settings.worker_agent_id:
        await run_worker(settings)
    else:
        await run_supervisor(settings)


def main() -> None:
    asyncio.run(main_async())


if __name__ == "__main__":
    main()
