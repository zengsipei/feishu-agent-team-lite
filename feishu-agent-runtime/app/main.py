from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI, Header, HTTPException, Request, status

from .agents import AgentRegistry
from .config import Settings, get_settings
from .llm import OpenAICompatibleClient
from .models import AgentSummary, CardAction, ChannelComment, ChannelMessage, RuntimeReply
from .runtime import AgentRuntime
from .store import RuntimeStore


def require_channel_auth(
    settings: Settings = Depends(get_settings),
    authorization: str | None = Header(default=None),
) -> None:
    if not settings.channel_auth_token:
        return
    expected = f"Bearer {settings.channel_auth_token}"
    if authorization != expected:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid channel auth token")


def build_runtime(settings: Settings) -> AgentRuntime:
    registry = AgentRegistry(settings.runtime_config_path)
    store = RuntimeStore(settings.resolved_database_path)
    if not settings.openai_api_key:
        raise RuntimeError("OPENAI_API_KEY is required")
    llm = OpenAICompatibleClient(
        api_key=settings.openai_api_key,
        base_url=settings.openai_base_url,
        model=settings.openai_model,
        timeout_seconds=settings.openai_timeout_seconds,
        max_retries=settings.openai_max_retries,
        retry_backoff_seconds=settings.openai_retry_backoff_seconds,
    )
    return AgentRuntime(
        registry=registry,
        store=store,
        llm=llm,
        max_context_messages=settings.max_context_messages,
    )


@asynccontextmanager
async def lifespan(app: FastAPI):
    settings = get_settings()
    settings.data_dir.mkdir(parents=True, exist_ok=True)
    app.state.runtime = build_runtime(settings)
    yield


app = FastAPI(title="Feishu Agent Runtime", version="0.1.0", lifespan=lifespan)


def get_runtime(request: Request) -> AgentRuntime:
    return request.app.state.runtime


@app.get("/health")
async def health(settings: Settings = Depends(get_settings)):
    return {
        "ok": True,
        "service": settings.service_name,
        "environment": settings.environment,
        "llm_provider": "openai_compatible",
    }


@app.get("/v1/agents", response_model=list[AgentSummary])
async def list_agents(
    _: None = Depends(require_channel_auth),
    runtime: AgentRuntime = Depends(get_runtime),
):
    return [
        AgentSummary(
            agent_id=agent.agent_id,
            agent_name=agent.agent_name,
            app_id=agent.app_id,
            source_memory_file=agent.source_memory_file,
            resolved_prompt_file=agent.resolved_prompt_file,
        )
        for agent in runtime.registry.list_agents()
    ]


@app.post("/v1/channel/messages", response_model=RuntimeReply)
async def handle_message(
    message: ChannelMessage,
    _: None = Depends(require_channel_auth),
    runtime: AgentRuntime = Depends(get_runtime),
):
    return await runtime.handle_message(message)


@app.post("/v1/channel/comments", response_model=RuntimeReply)
async def handle_comment(
    comment: ChannelComment,
    _: None = Depends(require_channel_auth),
    runtime: AgentRuntime = Depends(get_runtime),
):
    return await runtime.handle_comment(comment)


@app.post("/v1/channel/card-actions", response_model=RuntimeReply)
async def handle_card_action(
    action: CardAction,
    _: None = Depends(require_channel_auth),
    runtime: AgentRuntime = Depends(get_runtime),
):
    return await runtime.handle_card_action(action)
