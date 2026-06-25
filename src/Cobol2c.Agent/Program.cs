using Cobol2c.Agent;
using Cobol2c.Runner.Ta;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Options;

var host = Host.CreateDefaultBuilder(args)
    .ConfigureServices((ctx, services) =>
    {
        services.Configure<AgentOptions>(ctx.Configuration.GetSection("Agent"));

        services.AddSingleton(sp =>
        {
            var o = sp.GetRequiredService<IOptions<AgentOptions>>().Value;
            return new PowerShellHost(o.PowerShellExe, TimeSpan.FromMinutes(o.JobTimeoutMinutes));
        });

        services.AddSingleton<LocalExecutor>();

        services.AddHttpClient<AgentLoop>((sp, client) =>
        {
            var o = sp.GetRequiredService<IOptions<AgentOptions>>().Value;
            client.BaseAddress = new Uri(o.OrchestratorUrl.TrimEnd('/') + '/');
        });

        services.AddHostedService(sp => sp.GetRequiredService<AgentLoop>());
    })
    .Build();

await host.RunAsync();