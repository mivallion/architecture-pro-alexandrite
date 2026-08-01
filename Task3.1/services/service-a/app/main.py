"""service-a: расчётный сервис.

GET / — единственный REST API метод. При вызове обращается к service-b
(HTTP GET). Вызов инструментируется OpenTelemetry, поэтому server span
service-a, исходящий HTTP span и server span service-b попадают в один трейс.
"""

import os

import httpx
from fastapi import FastAPI
from opentelemetry import trace
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor

from app.tracing import init_tracing

init_tracing()

SERVICE_B_URL = os.environ.get("SERVICE_B_URL", "http://service-b:8080")

app = FastAPI(title="service-a")
FastAPIInstrumentor.instrument_app(app)

tracer = trace.get_tracer("service-a")


@app.get("/")
def read_root() -> dict:
    # Явный дочерний span поверх автоматической инструментации.
    with tracer.start_as_current_span("call-service-b"):
        with httpx.Client() as client:
            response = client.get(f"{SERVICE_B_URL}/")

    trace_id = format(trace.get_current_span().get_span_context().trace_id, "032x")
    return {
        "service": "service-a",
        "trace_id": trace_id,
        "service_b_response": response.json(),
    }
