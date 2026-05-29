use clap::Parser;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    nats_wrecking_ball::run_orchestrator(nats_wrecking_ball::OrchestratorCli::parse()).await
}
