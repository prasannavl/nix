use clap::Parser;

use abird_host_agent::cli::{Cli, execute};

fn main() {
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
