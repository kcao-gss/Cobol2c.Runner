using Cobol2c.Runner;
using Cobol2c.Runner.Configuration;
using Cobol2c.Runner.Jobs;
using Microsoft.Extensions.Options;
using Cobol2c.Runner.Reporting;
using Cobol2c.Runner.Sinks;
using Cobol2c.Runner.Ta;
using Cobol2c.Runner.Triage;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

var host = Host.CreateDefaultBuilder(args)
    .ConfigureServices((ctx, services) =>
    {
        services.Configure<RunnerOptions>(ctx.Configuration.GetSection("Runner"));

        var opts = ctx.Configuration.GetSection("Runner").Get<RunnerOptions>() ?? new RunnerOptions();

        // Shared infrastructure — factory avoids DI constructor ambiguity on PowerShellHost
        services.AddSingleton(sp =>
            new PowerShellHost(sp.GetRequiredService<IOptions<RunnerOptions>>().Value.PowerShellExe));
        services.AddSingleton<ITriageEngine, PowerShellTriageEngine>();

        // Job source, reporting, and sink stay local until Launchpad dashboard is built.
        services.AddSingleton<IJobSource, LocalFileJobSource>();
        services.AddSingleton<IBugReportGenerator, TemplateBugReportGenerator>();
        services.AddSingleton<IResultSink, LocalJsonResultSink>();

        // UseMocks=false → real TA execution via PowerShell (requires VPN + Runner__Ta01Pw env var).
        // UseMocks=true  → MockTaExecutor returns fixture paths instantly (default, no network needed).
        if (opts.UseMocks)
            services.AddSingleton<ITaExecutor, MockTaExecutor>();
        else
            services.AddSingleton<ITaExecutor, PowerShellTaExecutor>();

        services.AddHostedService<Worker>();
    })
    .Build();

await host.RunAsync();
