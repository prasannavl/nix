// Isolated browser leg of authority_proof.py. Credentials arrive over stdin.
const { chromium } = require("playwright");
const http = require("node:http");

async function main() {
  let input = "";
  for await (const chunk of process.stdin) input += chunk;
  const fixture = JSON.parse(input);
  let callback;
  const server = http.createServer((request, response) => {
    const url = new URL(request.url, "http://127.0.0.1");
    if (
      url.pathname !== "/api/abird.v1alpha1/login/callback" ||
      url.searchParams.get("state") !== fixture.params.state
    ) {
      response.writeHead(403);
      response.end();
      return;
    }
    callback = {
      code: url.searchParams.get("code"),
      state: url.searchParams.get("state"),
      origin: request.headers.origin || null,
    };
    response.writeHead(200, {
      "Cache-Control": "no-store",
      "Referrer-Policy": "no-referrer",
    });
    response.end("Login complete. Return to the application.");
  });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(fixture.listen_port, "127.0.0.1", resolve);
  });
  let browser;
  try {
    browser = await chromium.launch({
      executablePath: process.env.KANIDM_PROOF_BROWSER,
      headless: true,
    });
    // Only this disposable test instance uses a self-signed browser certificate.
    // The separate code-exchange client validates the exact fixture CA.
    const context = await browser.newContext({ ignoreHTTPSErrors: true });
    const page = await context.newPage();
    page.setDefaultTimeout(10000);
    await page.goto(
      fixture.url + "/ui/oauth2?" + new URLSearchParams(fixture.params),
    );
    await page.locator("#username").fill(fixture.username);
    await page.getByRole("button", { name: "Begin", exact: true }).click();
    await page.locator("input[type=password]:visible").fill(fixture.password);
    await page.getByRole("button", { name: "Submit", exact: true }).click();
    // The fixture pre-consents through a separate OAuth session before this leg.
    await page.waitForURL(fixture.params.redirect_uri + "**");
    if (!callback?.code) throw new Error("Missing callback");
    process.stdout.write(JSON.stringify(callback));
  } finally {
    if (browser) await browser.close();
    await new Promise((resolve) => server.close(resolve));
  }
}

main().catch(() => {
  // Playwright errors can contain filled values; do not print them.
  process.stderr.write("Isolated browser login proof failed\n");
  process.exitCode = 1;
});
