use clap::Parser;

use abird_host_agent::cli::{Cli, execute};

fn main() {
    if let Some(valid) =
        abird_host_agent::build_executor::capture_role::relay::entry(std::env::args_os().skip(1))
    {
        if !valid || abird_host_agent::build_executor::capture_role::relay::run().is_err() {
            eprintln!("owned input relay rejected");
            std::process::exit(1);
        }
        return;
    }
    let cli = Cli::parse();
    let json = cli.json;
    let streams_output = cli.streams_output();

    match execute(cli) {
        Ok(output) => {
            if json {
                println!("{}", serde_json::to_string(&output.value).unwrap());
            } else if !streams_output {
                println!("{}", output.human);
            }
        }
        Err(error) => {
            if json {
                eprintln!(
                    "{}",
                    serde_json::json!({
                        "ok": false,
                        "error": format!("{error:#}"),
                    })
                );
            } else {
                eprintln!("error: {error:#}");
            }
            std::process::exit(1);
        }
    }
}
