use clap::Parser;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let summary =
        nats_wrecking_ball::run_producer(nats_wrecking_ball::ProducerCli::parse()).await?;
    nats_wrecking_ball::log_summary(&summary);
    Ok(())
}
