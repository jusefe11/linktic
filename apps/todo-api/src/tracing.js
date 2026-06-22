const { NodeSDK } = require('@opentelemetry/sdk-node');
const { getNodeAutoInstrumentations } = require('@opentelemetry/auto-instrumentations-node');
const { OTLPTraceExporter } = require('@opentelemetry/exporter-trace-otlp-http');
const { B3Propagator, B3InjectEncoding } = require('@opentelemetry/propagator-b3');

const sdk = new NodeSDK({
  traceExporter: new OTLPTraceExporter({
    url: process.env.OTEL_EXPORTER_OTLP_TRACES_ENDPOINT ||
      'http://jaeger-collector.observability.svc.cluster.local:4318/v1/traces'
  }),
  textMapPropagator: new B3Propagator({
    injectEncoding: B3InjectEncoding.MULTI_HEADER
  }),
  instrumentations: [getNodeAutoInstrumentations({
    '@opentelemetry/instrumentation-fs': { enabled: false }
  })]
});

sdk.start();

const shutdown = () => sdk.shutdown().finally(() => process.exit(0));
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
