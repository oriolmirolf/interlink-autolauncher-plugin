from fastapi import FastAPI, Body, HTTPException, Query
from fastapi.responses import PlainTextResponse
from pydantic import BaseModel, ConfigDict
from typing import List, Union

from autolauncher_adapter import AutolauncherAdapter
from plugin_state import PluginState

import logging, traceback
log = logging.getLogger("autolauncher")

app = FastAPI(debug=True)
state = PluginState()
adapter = AutolauncherAdapter(state)


# ---- Pydantic base that tolerates extra fields from InterLink ----
class APIModel(BaseModel):
    model_config = ConfigDict(extra='ignore')


# ---- Models ----
class Metadata(APIModel):
    name: str | None = None
    namespace: str | None = None
    uid: str | None = None
    annotations: dict[str, str] | None = None


class Container(APIModel):
    name: str
    image: str
    # InterLink may send strings; accept both list and str
    command: list[str] | str | None = None
    args: list[str] | str | None = None


class PodSpec(APIModel):
    containers: List[Container]
    initContainers: List[Container] | None = None


class PodRequest(APIModel):
    metadata: Metadata
    spec: PodSpec


class Volume(APIModel):
    name: str


class Pod(APIModel):
    pod: PodRequest
    container: List[Volume] = []


class StateRunning(APIModel):
    startedAt: str | None = None


class StateTerminated(APIModel):
    exitCode: int
    reason: str | None = None


class StateWaiting(APIModel):
    reason: str | None = None
    message: str | None = None


class ContainerStates(APIModel):
    terminated: StateTerminated | None = None
    running: StateRunning | None = None
    waiting: StateWaiting | None = None


class ContainerStatus(APIModel):
    name: str
    state: ContainerStates


class PodStatus(APIModel):
    name: str
    UID: str
    JID: str | None = None
    namespace: str
    containers: List[ContainerStatus]


class CreateStruct(APIModel):
    PodUID: str
    PodJID: str


class LogOpts(APIModel):
    Tail: int | None = None
    LimitBytes: int | None = None
    Timestamps: bool | None = None
    Previous: bool = False


class LogRequest(APIModel):
    Namespace: str
    PodUID: str
    PodName: str
    ContainerName: str
    Opts: LogOpts


# ----- Helpers -----
def _uids_from_query(uid_param: List[str] | None) -> List[str]:
    """Support ?uid=a&uid=b and ?uid=a,b forms. Empty/None -> []."""
    out: List[str] = []
    if not uid_param:
        return out
    for u in uid_param:
        out.extend([p.strip() for p in u.split(",") if p.strip()])
    return out


# ----- Routes required by the guide -----
@app.post("/create", response_model=List[CreateStruct])
def create_pod(pods: Union[List[Pod], Pod]):
    """
    Accept either a single Pod object or a list of Pod objects.
    """
    try:
        pods_list = pods if isinstance(pods, list) else [pods]
        return adapter.create(pods_list)
    except Exception as e:
        logging.getLogger("autolauncher").error("Create failed", exc_info=True)
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/delete", response_model=str)
def delete_pod(pod: PodRequest):
    try:
        adapter.delete(pod)
        return "OK"
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/status", response_model=List[PodStatus])
def status_pod_get(uid: List[str] | None = Query(None, description="Repeat ?uid=x&uid=y or CSV ?uid=x,y")):
    """
    If no uid is provided (virtual-kubelet ping), return an empty list with 200 OK.
    """
    try:
        uids = _uids_from_query(uid)
        if not uids:
            return []
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
