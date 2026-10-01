# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.Telemetry.OTLP do
  @moduledoc """
  Logs and gauges over OTLP/HTTP protobuf, encoded with the exporter's own OTLP messages. Spans go
  through the OpenTelemetry SDK. `base` is a store's origin, such as `http://10.77.0.3:9428`.
  """

  def log(base, body, attributes \\ %{}, opts \\ []) do
    time = Keyword.get_lazy(opts, :time_unix_nano, fn -> System.os_time(:nanosecond) end)

    record = %{
      time_unix_nano: time,
      observed_time_unix_nano: time,
      severity_number: Keyword.get(opts, :severity_number, :SEVERITY_NUMBER_INFO),
      severity_text: Keyword.get(opts, :severity_text, "INFO"),
      body: any(body),
      attributes: kvs(attributes)
    }

    request = %{
      resource_logs: [
        %{resource: resource(opts), scope_logs: [%{scope: %{name: "uro"}, log_records: [record]}]}
      ]
    }

    post(
      base <> "/insert/opentelemetry/v1/logs",
      :opentelemetry_exporter_logs_service_pb.encode_msg(request, :export_logs_service_request)
    )
  end

  def gauge(base, name, value, attributes \\ %{}, opts \\ []) do
    time = Keyword.get_lazy(opts, :time_unix_nano, fn -> System.os_time(:nanosecond) end)
    point = %{time_unix_nano: time, value: {:as_double, value / 1}, attributes: kvs(attributes)}
    metric = %{name: name, data: {:gauge, %{data_points: [point]}}}

    request = %{
      resource_metrics: [
        %{resource: resource(opts), scope_metrics: [%{scope: %{name: "uro"}, metrics: [metric]}]}
      ]
    }

    post(
      base <> "/opentelemetry/v1/metrics",
      :opentelemetry_exporter_metrics_service_pb.encode_msg(
        request,
        :export_metrics_service_request
      )
    )
  end

  defp resource(opts),
    do: %{attributes: kvs(%{"service.name" => Keyword.get(opts, :service, "uro")})}

  defp kvs(attributes) do
    attributes
    |> Enum.map(fn {k, v} -> %{key: to_string(k), value: any(v)} end)
    |> Enum.sort_by(& &1.key)
  end

  defp any(v) when is_binary(v), do: %{value: {:string_value, v}}
  defp any(v) when is_boolean(v), do: %{value: {:bool_value, v}}
  defp any(v) when is_integer(v), do: %{value: {:int_value, v}}
  defp any(v) when is_float(v), do: %{value: {:double_value, v}}

  defp post(url, body) do
    case HTTPoison.post(url, body, [{"content-type", "application/x-protobuf"}]) do
      {:ok, %HTTPoison.Response{status_code: status}} when status in 200..299 -> :ok
      {:ok, %HTTPoison.Response{status_code: status, body: resp}} -> {:error, {status, resp}}
      {:error, reason} -> {:error, reason}
    end
  end
end
