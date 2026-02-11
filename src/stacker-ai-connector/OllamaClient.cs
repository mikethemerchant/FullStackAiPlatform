using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Extensions.Logging;

namespace Stacker.AiConnector;

/// <summary>
/// Represents a request to the Ollama API for text generation.
/// </summary>
public class OllamaGenerateRequest
{
    /// <summary>
    /// The model to use (e.g., "llama3").
    /// </summary>
    [JsonPropertyName("model")]
    public string Model { get; set; } = "llama3";

    /// <summary>
    /// The input prompt for generation.
    /// </summary>
    [JsonPropertyName("prompt")]
    public string Prompt { get; set; } = string.Empty;

    /// <summary>
    /// If true, the response will be a stream of tokens.
    /// </summary>
    [JsonPropertyName("stream")]
    public bool Stream { get; set; } = false;

    /// <summary>
    /// Temperature for sampling (0.0 to 1.0+).
    /// Higher = more randomness, lower = more deterministic.
    /// </summary>
    [JsonPropertyName("temperature")]
    public double? Temperature { get; set; }

    /// <summary>
    /// Optional context from previous request for continued generation.
    /// </summary>
    [JsonPropertyName("context")]
    public int[]? Context { get; set; }
}

/// <summary>
/// Represents a response chunk from the Ollama API.
/// </summary>
public class OllamaGenerateResponse
{
    /// <summary>
    /// The model used.
    /// </summary>
    [JsonPropertyName("model")]
    public string Model { get; set; } = string.Empty;

    /// <summary>
    /// Timestamp when the response was created (ISO 8601).
    /// </summary>
    [JsonPropertyName("created_at")]
    public string CreatedAt { get; set; } = string.Empty;

    /// <summary>
    /// The generated text (partial if streaming).
    /// </summary>
    [JsonPropertyName("response")]
    public string Response { get; set; } = string.Empty;

    /// <summary>
    /// True when generation is complete.
    /// </summary>
    [JsonPropertyName("done")]
    public bool Done { get; set; }

    /// <summary>
    /// Reason for completion (e.g., "stop", "length").
    /// </summary>
    [JsonPropertyName("done_reason")]
    public string? DoneReason { get; set; }

    /// <summary>
    /// Token context array for continuing generation.
    /// </summary>
    [JsonPropertyName("context")]
    public int[]? Context { get; set; }

    /// <summary>
    /// Total duration in nanoseconds (only when done=true).
    /// </summary>
    [JsonPropertyName("total_duration")]
    public long? TotalDuration { get; set; }

    /// <summary>
    /// Model load duration in nanoseconds.
    /// </summary>
    [JsonPropertyName("load_duration")]
    public long? LoadDuration { get; set; }

    /// <summary>
    /// Number of tokens in the prompt.
    /// </summary>
    [JsonPropertyName("prompt_eval_count")]
    public int? PromptEvalCount { get; set; }

    /// <summary>
    /// Time to process prompt in nanoseconds.
    /// </summary>
    [JsonPropertyName("prompt_eval_duration")]
    public long? PromptEvalDuration { get; set; }

    /// <summary>
    /// Number of tokens generated.
    /// </summary>
    [JsonPropertyName("eval_count")]
    public int? EvalCount { get; set; }

    /// <summary>
    /// Time to generate tokens in nanoseconds.
    /// </summary>
    [JsonPropertyName("eval_duration")]
    public long? EvalDuration { get; set; }
}

/// <summary>
/// HTTP client for interacting with the Ollama API.
/// Provides methods for text generation (streaming and non-streaming).
/// </summary>
public class OllamaClient
{
    private readonly HttpClient _httpClient;
    private readonly ILogger<OllamaClient> _logger;

    /// <summary>
    /// Initializes a new instance of the OllamaClient.
    /// </summary>
    /// <param name="httpClient">HTTP client configured with Ollama endpoint.</param>
    /// <param name="logger">Logger for structured logging.</param>
    public OllamaClient(HttpClient httpClient, ILogger<OllamaClient> logger)
    {
        _httpClient = httpClient ?? throw new ArgumentNullException(nameof(httpClient));
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
    }

    /// <summary>
    /// Checks if Ollama API is responsive (health check).
    /// </summary>
    /// <param name="cancellationToken">Cancellation token.</param>
    /// <returns>True if healthy, false otherwise.</returns>
    public async Task<bool> IsHealthyAsync(CancellationToken cancellationToken = default)
    {
        try
        {
            var response = await _httpClient.GetAsync("/", cancellationToken);
            if (response.IsSuccessStatusCode)
            {
                _logger.LogInformation("Ollama health check passed (HTTP {StatusCode})", response.StatusCode);
                return true;
            }

            _logger.LogWarning("Ollama health check failed (HTTP {StatusCode})", response.StatusCode);
            return false;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Ollama health check exception");
            return false;
        }
    }

    /// <summary>
    /// Generates text using Ollama (non-streaming).
    /// </summary>
    /// <param name="request">The generation request.</param>
    /// <param name="correlationId">Optional correlation ID for request tracing.</param>
    /// <param name="cancellationToken">Cancellation token.</param>
    /// <returns>The complete response with generated text and metrics.</returns>
    public async Task<OllamaGenerateResponse?> GenerateAsync(
        OllamaGenerateRequest request,
        string? correlationId = null,
        CancellationToken cancellationToken = default)
    {
        if (request == null) throw new ArgumentNullException(nameof(request));

        request.Stream = false; // Force non-streaming mode

        var sw = System.Diagnostics.Stopwatch.StartNew();

        try
        {
            _logger.LogInformation(
                "Ollama generate request (CorrelationId={CorrelationId}, Model={Model}, PromptLength={PromptLength})",
                correlationId, request.Model, request.Prompt.Length);

            var response = await _httpClient.PostAsJsonAsync(
                "/api/generate", request, cancellationToken: cancellationToken);

            if (!response.IsSuccessStatusCode)
            {
                _logger.LogError(
                    "Ollama API error (CorrelationId={CorrelationId}, StatusCode={StatusCode})",
                    correlationId, response.StatusCode);
                return null;
            }

            // Use JsonSerializer.Deserialize instead of deprecated ReadAsAsync
            var content = await response.Content.ReadAsStringAsync(cancellationToken);
            var result = JsonSerializer.Deserialize<OllamaGenerateResponse>(content);

            sw.Stop();

            _logger.LogInformation(
                "Ollama generate complete (CorrelationId={CorrelationId}, Latency={LatencyMs}ms, PromptTokens={PromptTokens}, GeneratedTokens={GeneratedTokens})",
                correlationId, sw.ElapsedMilliseconds, result?.PromptEvalCount ?? 0, result?.EvalCount ?? 0);

            return result;
        }
        catch (Exception ex)
        {
            sw.Stop();
            _logger.LogError(
                ex,
                "Ollama generate exception (CorrelationId={CorrelationId}, Latency={LatencyMs}ms)",
                correlationId, sw.ElapsedMilliseconds);
            throw;
        }
    }

    /// <summary>
    /// Generates text using Ollama with streaming responses.
    /// Yields NDJSON response chunks as they arrive.
    /// </summary>
    /// <param name="request">The generation request.</param>
    /// <param name="correlationId">Optional correlation ID for request tracing.</param>
    /// <param name="cancellationToken">Cancellation token.</param>
    /// <returns>Async enumerable of response chunks.</returns>
    public IAsyncEnumerable<OllamaGenerateResponse> GenerateStreamAsync(
        OllamaGenerateRequest request,
        string? correlationId = null,
        CancellationToken cancellationToken = default)
    {
        if (request == null) throw new ArgumentNullException(nameof(request));
        request.Stream = true;
        return GenerateStreamInternalAsync(request, correlationId, cancellationToken);
    }

    private async IAsyncEnumerable<OllamaGenerateResponse> GenerateStreamInternalAsync(
        OllamaGenerateRequest request,
        string? correlationId,
        [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken cancellationToken)
    {
        var sw = System.Diagnostics.Stopwatch.StartNew();

        _logger.LogInformation(
            "Ollama stream request (CorrelationId={CorrelationId}, Model={Model}, PromptLength={PromptLength})",
            correlationId, request.Model, request.Prompt.Length);

        using var cts = new System.Threading.CancellationTokenSource();

        HttpResponseMessage response;
        try
        {
            response = await _httpClient.PostAsJsonAsync(
                "/api/generate", request, cancellationToken: cts.Token);
        }
        catch (Exception ex)
        {
            sw.Stop();
            _logger.LogError(
                ex,
                "Ollama stream exception during request (CorrelationId={CorrelationId}, Latency={LatencyMs}ms)",
                correlationId, sw.ElapsedMilliseconds);
            throw;
        }

        if (!response.IsSuccessStatusCode)
        {
            _logger.LogError(
                "Ollama stream API error (CorrelationId={CorrelationId}, StatusCode={StatusCode})",
                correlationId, response.StatusCode);
            yield break;
        }

        using var stream = await response.Content.ReadAsStreamAsync(cts.Token);
        using var reader = new StreamReader(stream);

        int chunkCount = 0;
        long totalTokens = 0;

        try
        {
            while (!reader.EndOfStream)
            {
                var line = await reader.ReadLineAsync(cts.Token);
                if (string.IsNullOrWhiteSpace(line)) continue;

                var chunk = JsonSerializer.Deserialize<OllamaGenerateResponse>(line);
                if (chunk != null)
                {
                    chunkCount++;
                    totalTokens += chunk.EvalCount ?? 0;

                    _logger.LogDebug(
                        "Ollama stream chunk (CorrelationId={CorrelationId}, ChunkNum={ChunkNum}, TokensThisChunk={TokensThisChunk}, Done={Done})",
                        correlationId, chunkCount, chunk.EvalCount ?? 0, chunk.Done);

                    yield return chunk;
                }
            }
        }
        finally
        {
            sw.Stop();

            _logger.LogInformation(
                "Ollama stream complete (CorrelationId={CorrelationId}, Latency={LatencyMs}ms, Chunks={Chunks}, TotalTokens={TotalTokens})",
                correlationId, sw.ElapsedMilliseconds, chunkCount, totalTokens);
        }
    }
}
