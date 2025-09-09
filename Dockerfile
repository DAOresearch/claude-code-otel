# Multi-stage build for unified OTEL stack
FROM alpine:latest AS downloader

# Install curl and tar
RUN apk add --no-cache curl tar

# Download OpenTelemetry Collector
RUN curl -L -o otel-collector.tar.gz \
    "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/latest/download/otelcol-contrib_linux_amd64.tar.gz" && \
    tar -xzf otel-collector.tar.gz

# Download Prometheus
RUN curl -L -o prometheus.tar.gz \
    "https://github.com/prometheus/prometheus/releases/latest/download/prometheus-2.48.0.linux-amd64.tar.gz" || \
    curl -L -o prometheus.tar.gz \
    "https://github.com/prometheus/prometheus/releases/download/v2.48.0/prometheus-2.48.0.linux-amd64.tar.gz" && \
    tar -xzf prometheus.tar.gz && \
    mv prometheus-*/prometheus . && \
    mv prometheus-*/promtool .

# Final stage - use Grafana as base
FROM grafana/grafana-oss:latest

# Switch to root for installations
USER root

# Install supervisor and loki
RUN apk add --no-cache supervisor curl

# Install Loki
RUN curl -L -o /usr/local/bin/loki \
    "https://github.com/grafana/loki/releases/latest/download/loki-linux-amd64" && \
    chmod +x /usr/local/bin/loki

# Copy binaries from downloader stage
COPY --from=downloader /otelcol-contrib /usr/local/bin/otelcol
COPY --from=downloader /prometheus /usr/local/bin/prometheus
COPY --from=downloader /promtool /usr/local/bin/promtool

# Make binaries executable
RUN chmod +x /usr/local/bin/otelcol /usr/local/bin/prometheus /usr/local/bin/promtool

# Create necessary directories
RUN mkdir -p /etc/otel /etc/prometheus /etc/loki /var/lib/loki

# Copy configuration files
COPY collector-config.yaml /etc/otel/collector-config.yaml
COPY prometheus.yml /etc/prometheus/prometheus.yml
COPY grafana-datasources.yml /etc/grafana/provisioning/datasources/datasources.yml
COPY grafana-dashboards.yml /etc/grafana/provisioning/dashboards/dashboards.yml
COPY claude-code-dashboard.json /var/lib/grafana/dashboards/claude-code-dashboard.json

# Create Loki config
RUN cat > /etc/loki/local-config.yaml << 'EOF'
auth_enabled: false

server:
  http_listen_port: 3100

ingester:
  lifecycler:
    address: 127.0.0.1
    ring:
      kvstore:
        store: inmemory
      replication_factor: 1

schema_config:
  configs:
    - from: 2020-10-24
      store: boltdb-shipper
      object_store: filesystem
      schema: v11
      index:
        prefix: index_
        period: 24h

storage_config:
  boltdb_shipper:
    active_index_directory: /var/lib/loki/boltdb-shipper-active
    cache_location: /var/lib/loki/boltdb-shipper-cache
    shared_store: filesystem
  filesystem:
    directory: /var/lib/loki/chunks

compactor:
  working_directory: /var/lib/loki

limits_config:
  reject_old_samples: true
  reject_old_samples_max_age: 168h
EOF

# Create supervisor configuration
RUN cat > /etc/supervisor/conf.d/supervisord.conf << 'EOF'
[supervisord]
nodaemon=true
user=root

[program:grafana]
command=/run.sh
autostart=true
autorestart=true
stderr_logfile=/var/log/grafana.err.log
stdout_logfile=/var/log/grafana.out.log

[program:prometheus]
command=/usr/local/bin/prometheus --config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/var/lib/prometheus --web.console.libraries=/usr/share/prometheus/console_libraries --web.console.templates=/usr/share/prometheus/consoles --web.listen-address=0.0.0.0:9090
autostart=true
autorestart=true
stderr_logfile=/var/log/prometheus.err.log
stdout_logfile=/var/log/prometheus.out.log

[program:loki]
command=/usr/local/bin/loki -config.file=/etc/loki/local-config.yaml
autostart=true
autorestart=true
stderr_logfile=/var/log/loki.err.log
stdout_logfile=/var/log/loki.out.log

[program:otel-collector]
command=/usr/local/bin/otelcol --config=/etc/otel/collector-config.yaml
autostart=true
autorestart=true
stderr_logfile=/var/log/otel.err.log
stdout_logfile=/var/log/otel.out.log
EOF

# Create prometheus data directory
RUN mkdir -p /var/lib/prometheus && chown -R grafana:grafana /var/lib/prometheus

# Expose all ports
EXPOSE 3000 3100 4317 4318 8889 9090

# Start supervisor
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]