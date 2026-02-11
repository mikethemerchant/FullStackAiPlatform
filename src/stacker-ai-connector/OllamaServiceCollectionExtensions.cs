using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;

namespace Stacker.AiConnector;

/// <summary>
/// Extension methods for registering Ollama connector services in dependency injection.
/// </summary>
public static class OllamaServiceCollectionExtensions
{
    /// <summary>
    /// Adds the OllamaClient to the service collection.
    /// </summary>
    /// <param name="services">The service collection.</param>
    /// <param name="ollamaEndpoint">The Ollama API endpoint (e.g., "http://localhost:11434").</param>
    /// <returns>The service collection for chaining.</returns>
    public static IServiceCollection AddOllamaClient(
        this IServiceCollection services,
        string ollamaEndpoint)
    {
        if (string.IsNullOrWhiteSpace(ollamaEndpoint))
            throw new ArgumentException("Ollama endpoint cannot be null or empty.", nameof(ollamaEndpoint));

        // Register HttpClient for OllamaClient
        services
            .AddHttpClient<OllamaClient>()
            .ConfigureHttpClient(client =>
            {
                client.BaseAddress = new Uri(ollamaEndpoint);
                client.DefaultRequestHeaders.Add("User-Agent", "Stacker-AiConnector/1.0");
                // Set reasonable timeout for Ollama (model inference can take time)
                client.Timeout = TimeSpan.FromSeconds(300);
            });

        return services;
    }

    /// <summary>
    /// Adds the OllamaClient with custom HttpClientBuilder configuration.
    /// </summary>
    /// <param name="services">The service collection.</param>
    /// <param name="ollamaEndpoint">The Ollama API endpoint.</param>
    /// <param name="configureClient">Action to configure the HttpClient builder.</param>
    /// <returns>The service collection for chaining.</returns>
    public static IServiceCollection AddOllamaClient(
        this IServiceCollection services,
        string ollamaEndpoint,
        Action<IHttpClientBuilder> configureClient)
    {
        if (string.IsNullOrWhiteSpace(ollamaEndpoint))
            throw new ArgumentException("Ollama endpoint cannot be null or empty.", nameof(ollamaEndpoint));

        var builder = services
            .AddHttpClient<OllamaClient>()
            .ConfigureHttpClient(client =>
            {
                client.BaseAddress = new Uri(ollamaEndpoint);
                client.DefaultRequestHeaders.Add("User-Agent", "Stacker-AiConnector/1.0");
                client.Timeout = TimeSpan.FromSeconds(300);
            });

        configureClient(builder);
        return services;
    }
}
