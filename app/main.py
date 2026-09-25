"""Demo service for k8s-platform-lab.

Small on purpose: the point is not the business logic but the operational
surface — liveness, readiness, Prometheus metrics and a knob to generate
load — so that probes, HPA, alerts and chaos tests have something real to
act on.
"""

from __future__ import annotations

import asyncio
import logging
import os
import socket
import time
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, Query, Request, Response
from fastapi.responses import JSONResponse
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Gauge, Histogram, generate_latest

APP_VERSION = os.getenv("APP_VERSION", "dev")
INSTANCE = os.getenv("HOSTNAME", socket.gethostname())

# Simulated warm-up: the pod is alive immediately but not ready to serve.
# This is what makes readinessProbe visibly different from livenessProbe
# during a rolling update.
READY_DELAY_SECONDS = float(os.getenv("READY_DELAY_SECONDS", "3"))

# Admin endpoints are disabled unless a token is provided.
ADMIN_TOKEN = os.getenv("ADMIN_TOKEN", "")

# SLO: p95 of /api/* below 200ms. The bucket boundary at 0.2 is deliberate —
# histogram_quantile() interpolates inside a bucket, so an SLO threshold that
# is not a boundary gives you a number you cannot defend.
LATENCY_BUCKETS = (0.005, 0.01, 0.025, 0.05, 0.1, 0.2, 0.5, 1.0, 2.5, 5.0)

logger = logging.getLogger("app")
logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"), format="%(asctime)s %(levelname)s %(name)s %(message)s")

REQUESTS = Counter(
    "http_requests_total",
    "Total HTTP requests.",
    ["method", "path", "status"],
)
LATENCY = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency in seconds.",
    ["method", "path"],
    buckets=LATENCY_BUCKETS,
)
READY = Gauge("app_ready", "1 when the instance reports itself ready, 0 otherwise.")
BUILD_INFO = Gauge("app_build_info", "Build metadata, value is always 1.", ["version", "instance"])


class State:
    """Process-local readiness flag, flipped by startup and by /admin/ready."""

    ready: bool = False


state = State()


async def _warm_up() -> None:
    """Stands in for cache priming / migrations."""
    await asyncio.sleep(READY_DELAY_SECONDS)
    state.ready = True
    READY.set(1)
    logger.info("ready")


@asynccontextmanager
async def lifespan(_: FastAPI):
    READY.set(0)
    BUILD_INFO.labels(version=APP_VERSION, instance=INSTANCE).set(1)
    logger.info("starting version=%s instance=%s warmup=%ss", APP_VERSION, INSTANCE, READY_DELAY_SECONDS)

    # Deliberately not awaited: uvicorn does not accept connections until
    # startup returns, so blocking here would make /healthz unreachable during
    # warm-up and the liveness probe would restart a pod that is merely busy
    # booting. Background task => alive immediately, ready a little later.
    warmup = asyncio.create_task(_warm_up())

    yield

    warmup.cancel()

    # On SIGTERM Kubernetes has already removed the pod from Endpoints, but a
    # preStop hook in the chart gives in-flight requests time to finish.
    state.ready = False
    READY.set(0)
    logger.info("shutting down")


app = FastAPI(
    title="k8s-platform-lab",
    version=APP_VERSION,
    lifespan=lifespan,
)


def _route_template(request: Request) -> str:
    """Label by route template, never by raw URL.

    /api/work?ms=50 and /api/work?ms=900 must share one time series; using the
    raw path would let any caller create unbounded label cardinality and blow
    up Prometheus.
    """
    route = request.scope.get("route")
    return getattr(route, "path", None) or "unmatched"


@app.middleware("http")
async def observe(request: Request, call_next):
    # Scraping must not inflate the counters it exposes.
    if request.url.path == "/metrics":
        return await call_next(request)

    started = time.perf_counter()
    status_code = 500
    try:
        response = await call_next(request)
        status_code = response.status_code
        return response
    finally:
        elapsed = time.perf_counter() - started
        path = _route_template(request)
        LATENCY.labels(method=request.method, path=path).observe(elapsed)
        REQUESTS.labels(method=request.method, path=path, status=str(status_code)).inc()


@app.get("/", tags=["info"])
async def root() -> dict:
    """Identifies the instance, so a browser refresh shows Service load balancing."""
    return {"app": "k8s-platform-lab", "version": APP_VERSION, "instance": INSTANCE}


@app.get("/healthz", tags=["probes"])
async def healthz() -> dict:
    """Liveness: is the process still able to serve? Never checks dependencies —
    a failing dependency must not get every pod restarted in a loop."""
    return {"status": "ok"}


@app.get("/readyz", tags=["probes"])
async def readyz(response: Response) -> dict:
    """Readiness: should this instance receive traffic right now?"""
    if not state.ready:
        response.status_code = 503
        return {"status": "not ready"}
    return {"status": "ready"}


@app.get("/api/work", tags=["load"])
def work(ms: int = Query(default=50, ge=0, le=5000, description="CPU burn time in milliseconds")) -> dict:
    """Burns CPU for `ms` milliseconds.

    Gives the load test a way to push p95 past the SLO on demand and gives the
    HPA real CPU to scale on. Declared `def`, not `async def`, so FastAPI runs
    it in a worker thread instead of blocking the event loop (and the probes).
    """
    deadline = time.perf_counter() + ms / 1000
    iterations = 0
    while time.perf_counter() < deadline:
        iterations += 1
    return {"burned_ms": ms, "iterations": iterations, "instance": INSTANCE}


@app.post("/admin/ready", tags=["admin"])
async def set_ready(value: bool, token: str = Query(default="")) -> dict:
    """Flips readiness by hand, for chaos tests and rolling-update demos.

    Disabled unless ADMIN_TOKEN is set, because an unauthenticated endpoint
    that can pull a pod out of the load balancer is a denial-of-service knob.
    """
    if not ADMIN_TOKEN:
        raise HTTPException(status_code=404, detail="admin endpoints disabled")
    if token != ADMIN_TOKEN:
        raise HTTPException(status_code=403, detail="forbidden")

    state.ready = value
    READY.set(1 if value else 0)
    logger.warning("readiness set to %s via admin endpoint", value)
    return {"ready": value, "instance": INSTANCE}


@app.get("/metrics", tags=["observability"])
async def metrics() -> Response:
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.exception_handler(Exception)
async def unhandled(_: Request, exc: Exception) -> JSONResponse:
    logger.exception("unhandled error: %s", exc)
    return JSONResponse(status_code=500, content={"detail": "internal server error"})
