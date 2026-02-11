namespace Stacker.AiConnector;

/// <summary>
/// Usage examples for the OllamaClient.
/// </summary>
/// <remarks>
/// This class demonstrates how to use the OllamaClient in your Stacker API or other applications.
/// </remarks>
public static class OllamaClientUsageExample
{
    /// <summary>
    /// Example: Setup in Program.cs
    /// </summary>
    /// <remarks>
    /// Add to your Stacker API Program.cs:
    /// 
    /// var builder = WebApplication.CreateBuilder(args);
    /// builder.Services.AddOllamaClient("http://localhost:11434");
    /// 
    /// Then inject OllamaClient in your controllers/services.
    /// </remarks>
    public const string ProgramSetup = """
        var builder = WebApplication.CreateBuilder(args);
        
        // Add Ollama AI connector
        builder.Services.AddOllamaClient(
            builder.Configuration["Ollama:Endpoint"] ?? "http://localhost:11434");
        
        // ... rest of configuration
        var app = builder.Build();
        app.Run();
        """;

    /// <summary>
    /// Example: Using OllamaClient in a controller
    /// </summary>
    /// <remarks>
    /// Inject OllamaClient and use in your API endpoints.
    /// </remarks>
    public const string ControllerUsage = """
        [ApiController]
        [Route("api/[controller]")]
        public class AiController : ControllerBase
        {
            private readonly OllamaClient _ollamaClient;
            private readonly ILogger<AiController> _logger;
            private readonly IHttpContextAccessor _httpContextAccessor;
        
            public AiController(OllamaClient ollamaClient, ILogger<AiController> logger, IHttpContextAccessor httpContextAccessor)
            {
                _ollamaClient = ollamaClient;
                _logger = logger;
                _httpContextAccessor = httpContextAccessor;
            }
        
            [HttpGet("health")]
            public async Task<IActionResult> Health(CancellationToken cancellationToken)
            {
                var correlationId = _httpContextAccessor.HttpContext?.TraceIdentifier;
                var isHealthy = await _ollamaClient.IsHealthyAsync(cancellationToken);
                
                if (isHealthy)
                    return Ok(new { status = "healthy", correlationId });
                
                return ServiceUnavailable(new { status = "unhealthy", correlationId });
            }
        
            [HttpPost("generate")]
            public async Task<IActionResult> Generate([FromBody] OllamaGenerateRequest request, CancellationToken cancellationToken)
            {
                var correlationId = _httpContextAccessor.HttpContext?.TraceIdentifier;
                
                try
                {
                    var response = await _ollamaClient.GenerateAsync(request, correlationId, cancellationToken);
                    
                    if (response == null)
                        return StatusCode(503, new { error = "Ollama service unavailable", correlationId });
                    
                    return Ok(new { response, correlationId });
                }
                catch (Exception ex)
                {
                    _logger.LogError(ex, "Generate request failed (CorrelationId={CorrelationId})", correlationId);
                    return StatusCode(500, new { error = "Internal server error", correlationId });
                }
            }
        
            [HttpPost("generate-stream")]
            public async IAsyncEnumerable<string> GenerateStream(
                [FromBody] OllamaGenerateRequest request,
                [EnumeratorCancellation] CancellationToken cancellationToken)
            {
                var correlationId = _httpContextAccessor.HttpContext?.TraceIdentifier;
                
                await foreach (var chunk in _ollamaClient.GenerateStreamAsync(request, correlationId, null))
                {
                    yield return System.Text.Json.JsonSerializer.Serialize(chunk);
                }
            }
        }
        """;

    /// <summary>
    /// Example: Appsettings.json configuration
    /// </summary>
    public const string AppSettingsExample = """
        {
          "Logging": {
            "LogLevel": {
              "Default": "Information",
              "Stacker.AiConnector": "Debug"
            }
          },
          "Ollama": {
            "Endpoint": "http://localhost:11434",
            "Timeout": 300
          }
        }
        """;

    /// <summary>
    /// Example: Service-based usage (dependency injection pattern)
    /// </summary>
    public const string ServicePattern = """
        public interface IAiService
        {
            Task<string> GenerateResponseAsync(string prompt, string correlationId, CancellationToken cancellationToken);
        }
        
        public class AiService : IAiService
        {
            private readonly OllamaClient _ollamaClient;
            private readonly ILogger<AiService> _logger;
        
            public AiService(OllamaClient ollamaClient, ILogger<AiService> logger)
            {
                _ollamaClient = ollamaClient;
                _logger = logger;
            }
        
            public async Task<string> GenerateResponseAsync(string prompt, string correlationId, CancellationToken cancellationToken)
            {
                var request = new OllamaGenerateRequest
                {
                    Model = "llama3",
                    Prompt = prompt,
                    Stream = false,
                    Temperature = 0.7
                };
                
                var response = await _ollamaClient.GenerateAsync(request, correlationId, cancellationToken);
                
                return response?.Response ?? "No response from Ollama";
            }
        }
        """;
}
