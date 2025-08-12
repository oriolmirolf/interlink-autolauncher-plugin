from fastapi import FastAPI, Body, HTTPException, Query
from fastapi.responses import PlainTextResponse
from pydantic import BaseModel
from typing import List

from autolauncher_adapter import AutolauncherAdapter
from plugin_state import PluginState


app = FastAPI()
state = PluginState()
adapter = AutolauncherAdapter(state)

class Metadata(BaseModel):
    name: str | None = None
    namespace: str | None = None
    uid: str | None = None
    annotations: dict[str, str] | None = None

class Container(BaseModel):
    name: str
    image: str
    command: list[str] | None = None
    args: list[str] | None = None

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
    Previous: bool = False

class LogRequest(BaseModel):
    Namespace: str
    PodUID: str
    PodName: str
    ContainerName: str
    Opts: LogOpts


# ----- Helpers -----
def _uids_from_query(uid_param: List[str]) -> List[str]:
    """Support ?uid=a&uid=b and ?uid=a,b forms."""
    out: List[str] = []
    for u in uid_param:
        out.extend([p.strip() for p in u.split(",") if p.strip()])
    return out


# ----- Routes required by the guide -----
@app.post("/create", response_model=List[CreateStruct])
def create_pod(pods: List[Pod]):
    try:
        return adapter.create(pods)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/delete", response_model=str)
def delete_pod(pod: PodRequest):
    try:
        adapter.delete(pod)
        return "OK"
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/status", response_model=List[PodStatus])
def status_pod_get(uid: List[str] = Query(..., description="Repeat ?uid=x&uid=y or CSV ?uid=x,y")):
    try:
        uids = _uids_from_query(uid)
        # Adapter only needs UID; other fields are recovered from state.
        pods_minimal = [PodRequest(metadata=Metadata(uid=u), spec=PodSpec(containers=[])) for u in uids]
        return adapter.status(pods_minimal)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/getLogs", response_class=PlainTextResponse)
def get_logs_get(
    uid: str = Query(..., description="Pod UID"),
    containerName: str | None = Query(None),
    tail: int | None = Query(None),
    timestamps: bool = Query(False),
    previous: bool = Query(False),
    limitBytes: int | None = Query(None),
    namespace: str | None = Query(None),
    podName: str | None = Query(None),
):
    try:
        info = state.get(uid) or {}
        req = LogRequest(
            Namespace=namespace or info.get("namespace", "default"),
            PodUID=uid,
            PodName=podName or info.get("name", ""),
            ContainerName=containerName or info.get("container_name", ""),
            Opts=LogOpts(
                Tail=tail,
                LimitBytes=limitBytes,
                Timestamps=timestamps,
                Previous=previous,
            ),
        )
        return adapter.get_logs(req)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


# ----- Extras -----
@app.get("/health")
def health():
    return {"status": "ok"}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8001)
