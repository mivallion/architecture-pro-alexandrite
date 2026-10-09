"""service-b: сервис заказов.

GET / — единственный REST API метод. Возвращает статус сервиса и
trace_id текущего span. Если запрос пришёл от service-a с проброшенным
W3C Trace Context, trace_id в ответе совпадёт с trace_id service-a —
это признак того, что оба сервиса находятся в одном трейсе.
"""

from fastapi import FastAPI
from opentelemetry import trace
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor

from app.tracing import init_tracing

init_tracing()

app = FastAPI(title="service-b")
FastAPIInstrumentor.instrument_app(app)


@app.get("/")
def read_root() -> dict:
    span_context = trace.get_current_span().get_span_context()
    return {
        "service": "service-b",
        "trace_id": format(span_context.trace_id, "032x"),
        "message": "hello from service-b",
    }
