const SYNTAX_DIAGNOSTIC_SOURCE = "JETLS - syntax"
const TOPLEVEL_DIAGNOSTIC_SOURCE = "JETLS - top-level"
const INFERENCE_DIAGNOSTIC_SOURCE = "JETLS - inference"

function parsed_stream_to_diagnostics(parsed_stream::JS.ParseStream, filename::String)
    diagnostics = Diagnostic[]
    parsed_stream_to_diagnostics!(diagnostics, parsed_stream, filename)
    return diagnostics
end
function parsed_stream_to_diagnostics!(diagnostics::Vector{Diagnostic}, parsed_stream::JS.ParseStream, filename::String)
    source = JS.SourceFile(parsed_stream; filename)
    for diagnostic in parsed_stream.diagnostics
        push!(diagnostics, juliasyntax_diagnostic_to_diagnostic(diagnostic, source))
    end
end
function juliasyntax_diagnostic_to_diagnostic(diagnostic::JS.Diagnostic, source::JS.SourceFile)
    sline, scol = JS.source_location(source, JS.first_byte(diagnostic))
    start = Position(; line = sline-1, character = scol)
    eline, ecol = JS.source_location(source, JS.last_byte(diagnostic))
    var"end" = Position(; line = eline-1, character = ecol)
    return Diagnostic(;
        range = Range(; start, var"end"),
        severity =
            diagnostic.level === :error ? DiagnosticSeverity.Error :
            diagnostic.level === :warning ? DiagnosticSeverity.Warning :
            diagnostic.level === :note ? DiagnosticSeverity.Information :
            DiagnosticSeverity.Hint,
        message = diagnostic.message,
        source = SYNTAX_DIAGNOSTIC_SOURCE)
end

# TODO severity
function jet_result_to_diagnostics(file_uris, result::JET.JETToplevelResult)
    uri2diagnostics = Dict{URI,Vector{Diagnostic}}(uri => Diagnostic[] for uri in file_uris)
    jet_result_to_diagnostics!(uri2diagnostics, result)
    return uri2diagnostics
end

function jet_result_to_diagnostics!(uri2diagnostics::Dict{URI,Vector{Diagnostic}}, result::JET.JETToplevelResult)
    postprocessor = JET.PostProcessor(result.res.actual2virtual)
    for report in result.res.toplevel_error_reports
        diagnostic = jet_toplevel_error_report_to_diagnostic(postprocessor, report)
        filename = report.file
        filename === :none && continue
        if startswith(filename, "Untitled")
            uri = filename2uri(filename)
        else
            uri = filepath2uri(to_full_path(filename))
        end
        push!(uri2diagnostics[uri], diagnostic)
    end
    for report in result.res.inference_error_reports
        diagnostic = jet_inference_error_report_to_diagnostic(postprocessor, report)
        topframeidx = first(inference_error_report_stack(report))
        topframe = report.vst[topframeidx]
        topframe.file === :none && continue # TODO Figure out why this is necessary
        filename = String(topframe.file)
        if startswith(filename, "Untitled")
            uri = filename2uri(filename)
        else
            uri = filepath2uri(to_full_path(filename))
        end
        push!(uri2diagnostics[uri], diagnostic)
    end
end

frame_module(frame) = let def = frame.linfo.def
    if def isa Method
        def = def.module
    end
    return def
end

function jet_toplevel_error_report_to_diagnostic(postprocessor::JET.PostProcessor, @nospecialize report::JET.ToplevelErrorReport)
    if report isa JET.ParseErrorReport
        return juliasyntax_diagnostic_to_diagnostic(report.diagnostic, report.source)
    end
    message = JET.with_bufferring(:limit=>true) do io
        JET.print_report(io, report)
    end |> postprocessor
    return Diagnostic(;
        range = line_range(fixed_line_number(report.line)),
        severity = DiagnosticSeverity.Error,
        message,
        source = TOPLEVEL_DIAGNOSTIC_SOURCE)
end

function jet_inference_error_report_to_diagnostic(postprocessor::JET.PostProcessor, @nospecialize report::JET.InferenceErrorReport)
    rstack = inference_error_report_stack(report)
    topframe = report.vst[first(rstack)]
    message = JET.with_bufferring(:limit=>true) do io
        JET.print_report_message(io, report)
    end |> postprocessor
    relatedInformation = DiagnosticRelatedInformation[
        let frame = report.vst[rstack[i]],
            message = postprocessor(sprint(JET.print_frame_sig, frame, JET.PrintConfig()))
            DiagnosticRelatedInformation(;
                location = Location(;
                    uri = filepath2uri(to_full_path(frame.file)),
                    range = jet_frame_to_range(frame)),
                message)
        end
        for i = 2:length(rstack)]
    return Diagnostic(;
        range = jet_frame_to_range(topframe),
        severity = inference_error_report_severity(report),
        message,
        source = INFERENCE_DIAGNOSTIC_SOURCE,
        relatedInformation)
end

function jet_frame_to_range(frame)
    line = JET.fixed_line_number(frame)
    return line_range(fixed_line_number(line))
end

fixed_line_number(line) = line == 0 ? line : line - 1

function line_range(line::Int)
    start = Position(; line, character=0)
    var"end" = Position(; line, character=Int(typemax(Int32)))
    return Range(; start, var"end")
end

# textDocument/publishDiagnostics
# -------------------------------

function notify_full_diagnostics!(server::Server)
    uri2diagnostics = Dict{URI,Vector{Diagnostic}}()
    for (uri, analysis_info) in server.state.analysis_cache
        if analysis_info isa OutOfScope
            continue
        end
        diagnostics = get!(Vector{Diagnostic}, uri2diagnostics, uri)
        for analysis_unit in analysis_info
            full_diagnostics = get(analysis_unit.result.uri2diagnostics, uri, nothing)
            if full_diagnostics !== nothing
                append!(diagnostics, full_diagnostics)
            end
        end
    end
    notify_diagnostics!(server, uri2diagnostics)
end

function notify_diagnostics!(server::Server, uri2diagnostics)
    for (uri, diagnostics) in uri2diagnostics
        send(server, PublishDiagnosticsNotification(;
            params = PublishDiagnosticsParams(;
                uri,
                diagnostics)))
    end
end

# textDocument/diagnostic
# -----------------------

const DIAGNOSTIC_REGISTRATION_ID = "jetls-diagnostic"
const DIAGNOSTIC_REGISTRATION_METHOD = "textDocument/diagnostic"

function diagnostic_options()
    return DiagnosticOptions(;
        identifier = "JETLS/textDocument/diagnostic",
        interFileDependencies = false,
        workspaceDiagnostics = false)
end

function diagnostic_registration()
    (; identifier, interFileDependencies, workspaceDiagnostics) = diagnostic_options()
    return Registration(;
        id = DIAGNOSTIC_REGISTRATION_ID,
        method = DIAGNOSTIC_REGISTRATION_METHOD,
        registerOptions = DiagnosticRegistrationOptions(;
            documentSelector = DEFAULT_DOCUMENT_SELECTOR,
            identifier,
            interFileDependencies,
            workspaceDiagnostics)
    )
end

# # For dynamic registrations during development
# unregister(currently_running, Unregistration(;
#     id=DIAGNOSTIC_REGISTRATION_ID,
#     method=DIAGNOSTIC_REGISTRATION_METHOD))
# register(currently_running, diagnostic_resistration())

const empty_diagnostics = Diagnostic[]

function handle_DocumentDiagnosticRequest(server::Server, msg::DocumentDiagnosticRequest)
    uri = msg.params.textDocument.uri
    file_info = get_fileinfo(server.state, uri)
    if file_info === nothing
        return send(server,
            DocumentDiagnosticResponse(;
                id = msg.id,
                result = nothing,
                error = file_cache_error(uri;
                    data = DiagnosticServerCancellationData(; retriggerRequest = true))))
    end
    parsed_stream = file_info.parsed_stream
    if isempty(parsed_stream.diagnostics)
        diagnostics = empty_diagnostics
    else
        filename = uri2filename(uri)
        @assert !isnothing(filename) "Unsupported URI: $uri"
        diagnostics = parsed_stream_to_diagnostics(parsed_stream, filename)
    end
    return send(server,
        DocumentDiagnosticResponse(;
            id = msg.id,
            result = RelatedFullDocumentDiagnosticReport(;
                items = diagnostics)))
end
