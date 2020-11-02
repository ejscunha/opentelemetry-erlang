defmodule OtelTests do
  use ExUnit.Case, async: true

  require OpenTelemetry.Tracer, as: Tracer
  require OpenTelemetry.Span, as: Span
  require OpenTelemetry.Ctx, as: Ctx

  require Record
  @fields Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  Record.defrecordp(:span, @fields)

  @fields Record.extract(:span_ctx, from_lib: "opentelemetry_api/include/opentelemetry.hrl")
  Record.defrecordp(:span_ctx, @fields)

  @event_fields Record.extract(:event, from_lib: "opentelemetry_api/include/opentelemetry.hrl")
  Record.defrecordp(:event, @event_fields)

  test "use Tracer to set current active Span's attributes" do
    :otel_batch_processor.set_exporter(:otel_exporter_pid, self())
    OpenTelemetry.register_tracer(:test_tracer, "0.1.0")

    Tracer.with_span "span-1" do
      Tracer.set_attribute("attr-1", "value-1")
      Tracer.set_attributes([{"attr-2", "value-2"}])
    end

    assert_receive {:span,
                    span(
                      name: "span-1",
                      attributes: [{"attr-1", "value-1"}, {"attr-2", "value-2"}]
                    )}
  end

  test "use Tracer to start a Span as currently active with an explicit parent" do
    :otel_batch_processor.set_exporter(:otel_exporter_pid, self())
    OpenTelemetry.register_tracer(:test_tracer, "0.1.0")

    s1 = Tracer.start_span("span-1")
    ctx = Tracer.set_current_span(Ctx.new(), s1)

    Tracer.with_span ctx, "span-2", %{} do
      Tracer.set_attribute("attr-1", "value-1")
      Tracer.set_attributes([{"attr-2", "value-2"}])
    end

    span_ctx(span_id: parent_span_id) = Span.end_span(s1)

    assert_receive {:span,
                    span(
                      name: "span-1",
                      attributes: []
                    )}

    assert_receive {:span,
                    span(
                      name: "span-2",
                      parent_span_id: ^parent_span_id,
                      attributes: [{"attr-1", "value-1"}, {"attr-2", "value-2"}]
                    )}
  end

  test "use Span to set attributes" do
    :otel_batch_processor.set_exporter(:otel_exporter_pid, self())

    s = Tracer.start_span("span-2")
    Span.set_attribute(s, "attr-1", "value-1")
    Span.set_attributes(s, [{"attr-2", "value-2"}])

    assert span_ctx() = Span.end_span(s)

    assert_receive {:span,
                    span(
                      name: "span-2",
                      attributes: [{"attr-1", "value-1"}, {"attr-2", "value-2"}]
                    )}
  end

  test "use explicit Context for parent of started Span" do
    :otel_batch_processor.set_exporter(:otel_exporter_pid, self())

    s1 = Tracer.start_span("span-1")
    ctx = Tracer.set_current_span(Ctx.new(), s1)

    # span-2 will have s1 as the parent since s1 is the current span in `ctx`
    s2 = Tracer.start_span(ctx, "span-2", %{})

    # span-3 will have no parent because it uses the current context
    s3 = Tracer.start_span("span-3")

    Span.set_attribute(s1, "attr-1", "value-1")
    Span.set_attributes(s1, [{"attr-2", "value-2"}])

    span_ctx(span_id: s1_span_id) = Span.end_span(s1)

    assert span_ctx() = Span.end_span(s2)
    assert span_ctx() = Span.end_span(s3)

    assert_receive {:span,
                    span(
                      name: "span-1",
                      parent_span_id: :undefined,
                      attributes: [{"attr-1", "value-1"}, {"attr-2", "value-2"}]
                    )}

    assert_receive {:span,
                    span(
                      name: "span-2",
                      parent_span_id: ^s1_span_id
                    )}

    assert_receive {:span,
                    span(
                      name: "span-3",
                      parent_span_id: :undefined
                    )}
  end

  test "Span.record_exception/4 should return false if passed an invalid exception" do
    Tracer.with_span "span-3" do
      refute OpenTelemetry.Span.record_exception(Tracer.current_span_ctx(), :not_an_exception)
    end
  end

  test "Span.record_exception/4 should add an exception event to the span" do
    :otel_batch_processor.set_exporter(:otel_exporter_pid, self())
    s = Tracer.start_span("span-4")

    try do
      raise RuntimeError, "my error message"
    rescue
      ex ->
        assert Span.record_exception(s, ex, __STACKTRACE__)
        assert Span.end_span(s)

        stacktrace = Exception.format_stacktrace(__STACKTRACE__)

        assert_receive {:span,
                        span(
                          name: "span-4",
                          events: [
                            event(
                              name: "exception",
                              attributes: [
                                {"exception.type", "Elixir.RuntimeError"},
                                {"exception.message", "my error message"},
                                {"exception.stacktrace", ^stacktrace}
                              ]
                            )
                          ]
                        )}
    end
  end
end
