using Cobol2c.Runner;
using Cobol2c.Runner.Configuration;
using Cobol2c.Runner.Jobs;
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

        // Shared infrastructure
        services.AddSingleton<PowerShellHost>();
        services.AddSingleton<ITriageEngine, PowerShellTriageEngine>();

        if (opts.UseMocks)
        {
            // PoC: all local, no network, no credentials
            services.AddSingleton<IJobSource, LocalFileJobSource>();
            services.AddSingleton<ITaExecutor, MockTaExecutor>();
            services.AddSingleton<IBugReportGenerator, TemplateBugReportGenerator>();
            services.AddSingleton<IResultSink, LocalJsonResultSink>();
        }
        else
        {
            // Production: Launchpad Job Client + real TA executor + Claude report + HTTP sink
            // Each of these requires env/secrets config — see README.md §Go-Live Swap Table
            services.AddSingleton<IJobSource, HttpJobSource>();
            services.AddSingleton<ITaExecutor, PowerShellTaExecutor>();
            services.AddSingleton<IBugReportGenerator, ClaudeBugReportGenerator>();
            services.AddSingleton<IResultSink, HttpResultSink>();
        }

        services.AddHostedService<Worker>();
    })
    .Build();

await host.RunAsync();
