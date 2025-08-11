from fastapi import FastAPI, Body, HTTPException
from typing import List
from pydantic import BaseModel
from fastapi.responses import PlainTextResponse  # NEW
from autolauncher_adapter import AutolauncherAdapter
from plugin_state import PluginState

app = FastAPI()
state = PluginState()
adapter = AutolauncherAdapter(state)

# ----- Schemas (align with interLink plugin schema) -----
class Metadata(BaseModel):
    name: str | None = None
    namespace: str | None = None
    uid: str | None = None
    annotations: dict[str, str] | None = {}

class Container(BaseModel):
    name: str
    image: str
    command: list[str] | None = None
    args: list[str] | None = []

class PodSpec(BaseModel):
    containers: List[Container]
    initContainers: List[Container] | None = None

class PodRequest(BaseModel):
    metadata: Metadata
    spec: PodSpec

class Volume(BaseModel):
    name: str

class Pod(BaseModel):
    pod: PodRequest
    container: List[Volume] = []

class StateRunning(BaseModel):
    startedAt: str | None = None

class StateTerminated(BaseModel):
    exitCode: int
    reason: str | None = None

class StateWaiting(BaseModel):
    reason: str | None = None
    message: str | None = None

class ContainerStates(BaseModel):
    terminated: StateTerminated | None = None
    running: StateRunning | None = None
    waiting: StateWaiting | None = None

class ContainerStatus(BaseModel):
    name: str
    state: ContainerStates

class PodStatus(BaseModel):
    name: str
    UID: str
    JID: str | None = None
    namespace: str
    containers: List[ContainerStatus]

class CreateStruct(BaseModel):
    PodUID: str
    PodJID: str

class LogOpts(BaseModel):
    Tail: int | None = None
    LimitBytes: int | None = None
    Timestamps: bool | None = None
    Previous: bool

class LogRequest(BaseModel):
    Namespace: str
    PodUID: str
    PodName: str
    ContainerName: str
    Opts: LogOpts

# ----- Routes -----
@app.get("/health")
def health():
    return {"status": "ok"}

@app.post("/create", response_model=List[CreateStruct])
def create_pod(pods: List[Pod]):
    try:
        return adapter.create(pods)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/status", response_model=List[PodStatus])
def status_pod(pods: List[PodRequest] = Body(...)):
    try:
        return adapter.status(pods)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/getLogs", response_class=PlainTextResponse)
def get_logs(req: LogRequest = Body(...)):
    try:
        return adapter.get_logs(req)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/delete", response_model=str)
def delete_pod(pod: PodRequest):
    try:
        adapter.delete(pod)
        return "OK"
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
