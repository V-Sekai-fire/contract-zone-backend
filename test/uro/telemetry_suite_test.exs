# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
defmodule Uro.TelemetrySuiteTest do
  # Uro's spans, logs and gauges read back from the VictoriaMetrics suite tools/offline runs: per
  # signal a unit test (it arrives), a falsifiable one (a wrong expectation and a name never sent
  # are both caught) and an identity one (what reads back is what was sent, and reads repeat).
  use ExUnit.Case, async: false
  require OpenTelemetry.Tracer
  alias Uro.Telemetry.OTLP

  @moduletag :suite
  @moduletag timeout: 300_000

  setup_all do
    {:ok, _} = Application.ensure_all_started(:httpoison)
    base = System.fetch_env!("URO_SUITE_URL")
    run = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    # The metrics store keeps milliseconds, so one millisecond-aligned time serves all three.
    time = div(System.os_time(:nanosecond), 1_000_000) * 1_000_000

    span_name = "suite-span-#{run}"

    {trace_id, span_id} =
      OpenTelemetry.Tracer.with_span span_name, %{
        attributes: %{"case" => "identity", "run" => run}
      } do
        ctx = OpenTelemetry.Tracer.current_span_ctx()
        {OpenTelemetry.Span.hex_trace_id(ctx), OpenTelemetry.Span.hex_span_id(ctx)}
      end

    :ok = :otel_tracer_provider.force_flush()
    attrs = %{"case" => "identity", "run" => run}
    :ok = OTLP.log("#{base}:9428", "suite-log-#{run}", attrs, time_unix_nano: time)
    :ok = OTLP.gauge("#{base}:8428", "suite_gauge_#{run}", 42.5, attrs, time_unix_nano: time)

    %{
      base: base,
      run: run,
      span: %{
        "name" => span_name,
        "trace_id" => to_string(trace_id),
        "span_id" => to_string(span_id),
        "span_attr:case" => "identity",
        "span_attr:run" => run,
        "resource_attr:service.name" => System.get_env("OTEL_SERVICE_NAME", "uro")
      },
      log: %{
        "_msg" => "suite-log-#{run}",
        "_time_ms" => div(time, 1_000_000),
        "case" => "identity",
        "run" => run,
        "service.name" => "uro",
        "severity_number" => "9",
        "severity_text" => "INFO"
      },
      gauge: %{
        "__name__" => "suite_gauge_#{run}",
        "case" => "identity",
        "run" => run,
        "service.name" => "uro",
        "value" => 42.5,
        "timestamp" => div(time, 1_000_000)
      }
    }
  end

  describe "span" do
    test "unit: the span Uro's SDK exported reads back", c do
      assert [_] = eventually(fn -> span(c, c.span["name"]) end)
    end

    test "falsifiable: a changed attribute and a span never sent are caught", c do
      [got] = eventually(fn -> span(c, c.span["name"]) end)
      assert diff(%{c.span | "span_attr:run" => "not-#{c.run}"}, got) == ["span_attr:run"]
      assert span(c, c.span["name"] <> "-never-sent") == []
    end

    test "identity: name, ids and attributes read back as sent, twice", c do
      [got] = eventually(fn -> span(c, c.span["name"]) end)
      assert diff(c.span, got) == []
      assert span(c, c.span["name"]) == [got]
    end
  end

  describe "log" do
    test "unit: the OTLP log record reads back", c do
      assert [_] = eventually(fn -> log(c, c.log["_msg"]) end)
    end

    test "falsifiable: a changed attribute and a body never sent are caught", c do
      [got] = eventually(fn -> log(c, c.log["_msg"]) end)
      assert diff(%{c.log | "severity_text" => "WARN"}, got) == ["severity_text"]
      assert log(c, c.log["_msg"] <> "-never-sent") == []
    end

    test "identity: body, time, severity and attributes read back as sent, twice", c do
      [got] = eventually(fn -> log(c, c.log["_msg"]) end)
      assert diff(c.log, got) == []
      assert log(c, c.log["_msg"]) == [got]
    end
  end

  describe "gauge" do
    test "unit: the OTLP gauge point reads back", c do
      assert [_] = eventually(fn -> gauge(c, c.gauge["__name__"]) end)
    end

    test "falsifiable: a changed value and a gauge never sent are caught", c do
      [got] = eventually(fn -> gauge(c, c.gauge["__name__"]) end)
      assert diff(%{c.gauge | "value" => 42.25}, got) == ["value"]
      assert gauge(c, c.gauge["__name__"] <> "_never_sent") == []
    end

    test "identity: name, labels, value and time read back as sent, twice", c do
      [got] = eventually(fn -> gauge(c, c.gauge["__name__"]) end)
      assert diff(c.gauge, got) == []
      assert gauge(c, c.gauge["__name__"]) == [got]
    end
  end

  defp diff(want, got), do: for({k, v} <- want, Map.get(got, k) != v, do: k)

  # The traces store shows a span only after its 30 s latency offset, hence the 90 s of polling.
  defp eventually(read, tries \\ 90) do
    case read.() do
      [] when tries > 1 ->
        Process.sleep(1_000)
        eventually(read, tries - 1)

      rows ->
        rows
    end
  end

  defp span(c, name), do: logsql(c, 10428, ~s(name:="#{name}"))

  defp log(c, body) do
    for row <- logsql(c, 9428, ~s(_msg:="#{body}")) do
      {:ok, at, _} = DateTime.from_iso8601(row["_time"])
      Map.put(row, "_time_ms", DateTime.to_unix(at, :millisecond))
    end
  end

  defp gauge(c, name) do
    for row <- lines(get(c, 8428, "/api/v1/export", %{"match[]" => name})),
        {value, ts} <- Enum.zip(row["values"], row["timestamps"]) do
      Map.merge(row["metric"], %{"value" => value, "timestamp" => ts})
    end
  end

  defp logsql(c, port, query) do
    lines(get(c, port, "/select/logsql/query", %{"query" => "_time:1h " <> query}))
  end

  defp get(c, port, path, params) do
    {:ok, %HTTPoison.Response{status_code: 200, body: body}} =
      HTTPoison.get("#{c.base}:#{port}#{path}?" <> URI.encode_query(params))

    body
  end

  defp lines(body), do: body |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
end
