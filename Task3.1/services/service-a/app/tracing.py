"""Настройка OpenTelemetry для service-a.

Инициализирует TracerProvider с ресурсом service.name, подключает OTLP
gRPC-экспортёр (по умолчанию http://localhost:4317, в Kubernetes — адрес
Jaeger Collector) и включает автоматическую инструментацию HTTP-клиента
httpx: на каждый исходящий вызов создаётся span и пробрасывается
W3C Trace Context (заголовок traceparent).
"""

import os

from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor


def init_tracing() -> None:
    resource = Resource.create(
        {
            "service.name": os.environ.get("OTEL_SERVICE_NAME", "unknown-service"),
        }
    )

    provider = TracerProvider(resource=resource)
    exporter = OTLPSpanExporter(
        endpoint=os.environ.get(
            "OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4317"
        ),
        insecure=True,
    )
    provider.add_span_processor(BatchSpanProcessor(exporter))
    trace.set_tracer_provider(provider)

    HTTPXClientInstrumentor().instrument()
