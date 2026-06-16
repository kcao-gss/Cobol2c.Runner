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

// Single-instance guard: prevent two workers racing over the same fixtures/jobs/ directory.
// If another instance is already running, log and exit immediately.
using var mutex = new Mutex(initiallyOwned: false, name: "Global\\Cobol2c.Runner");
if (!mutex.WaitOne(millisecondsTimeout: 0))
{
    Console.Error.WriteLine("[Cobol2c.Runner] Another instance is already running — exiting. " +
        "Stop the existing process before starting a new one.");
    return 1;
}

var host = Host.CreateDefaultBuilder(args)
    .ConfigureServices((ctx, services) =>
    {
        services.Configure<RunnerOptions>(ctx.Configuration.GetSection("Runner"));

        var opts = ctx.Configuration.GetSection("Runner").Get<RunnerOptions>() ?? new RunnerOptions();

        // Shared infrastructure — factory avoids DI constructor ambiguity on PowerShellHost
        services.AddSingleton(sp =>
        {
            var o = sp.GetRequiredService<IOptions<RunnerOptions>>().Value;
            return new PowerShellHost(o.PowerShellExe, TimeSpan.FromMinutes(o.JobTimeoutMinutes));
        });
        services.AddSingleton<ITriageEngine, PowerShellTriageEngine>();
        services.AddSingleton<MachineSelector>();

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

try
{
    await host.RunAsync();
}
finally
{
    mutex.ReleaseMutex();
}
return 0;
