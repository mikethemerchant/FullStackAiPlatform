namespace Stacker.Api.Middleware;

/// <summary>
/// Middleware to generate and propagate correlation IDs for end-to-end request tracing.
/// Checks for incoming X-Correlation-ID header or generates a new GUID.
/// Adds correlation ID to HttpContext, response headers, and Serilog log context.
/// </summary>
public class CorrelationIdMiddleware
{
    private const string CorrelationIdHeaderName = "X-Correlation-ID";
    private readonly RequestDelegate _next;
    private readonly ILogger<CorrelationIdMiddleware> _logger;

    public CorrelationIdMiddleware(RequestDelegate next, ILogger<CorrelationIdMiddleware> logger)
    {
        _next = next;
        _logger = logger;
    }

    public async Task InvokeAsync(HttpContext context)
    {
        // Check for existing correlation ID in request headers
        string correlationId = context.Request.Headers[CorrelationIdHeaderName].FirstOrDefault()
            ?? Guid.NewGuid().ToString();

        // Store in HttpContext for access throughout the request pipeline
        context.Items["CorrelationId"] = correlationId;

        // Add to response headers for client traceability
        context.Response.OnStarting(() =>
        {
            if (!context.Response.Headers.ContainsKey(CorrelationIdHeaderName))
            {
                context.Response.Headers.TryAdd(CorrelationIdHeaderName, correlationId);
            }
            return Task.CompletedTask;
        });

        // Push to Serilog LogContext so it appears in all logs for this request
        using (Serilog.Context.LogContext.PushProperty("CorrelationId", correlationId))
        {
            _logger.LogDebug("Request started with CorrelationId: {CorrelationId}", correlationId);
            
            await _next(context);
            
            _logger.LogDebug("Request completed with CorrelationId: {CorrelationId}", correlationId);
        }
    }
}

/// <summary>
/// Extension methods to simplify middleware registration in Program.cs
/// </summary>
public static class CorrelationIdMiddlewareExtensions
{
    public static IApplicationBuilder UseCorrelationId(this IApplicationBuilder builder)
    {
        return builder.UseMiddleware<CorrelationIdMiddleware>();
    }

    /// <summary>
    /// Helper method to retrieve correlation ID from HttpContext
    /// </summary>
    public static string? GetCorrelationId(this HttpContext context)
    {
        return context.Items["CorrelationId"]?.ToString();
    }
}
