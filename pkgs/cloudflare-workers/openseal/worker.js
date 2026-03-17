/**
 * Welcome to Cloudflare Workers! This is your first worker.
 *
 * - Run "npm run dev" in your terminal to start a development server
 * - Open a browser tab at http://localhost:8787/ to see your worker in action
 * - Run "npm run deploy" to publish your worker
 *
 * Learn more at https://developers.cloudflare.com/workers/
 */

export default {
  async fetch(request, env, ctx) {
    const fonts = ``;

    const html = `
    <html><head>
      <meta charset="UTF-8">
      <title>Openseal AI</title>
      <meta name="description" content="The world's first safe, sealed AI operating system stack - built in the open">
      <link rel="canonical" href="https://ssi.inc">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <link rel="preconnect" href="https://fonts.googleapis.com">
      <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
      <link href="https://fonts.googleapis.com/css2?family=Inconsolata:wght@200..900&display=swap" rel="stylesheet">
      <style>
      body { 
        line-height: 1.4;
          font-size: 16px;
          margin: 50px auto;
          padding: 0 25px;
          max-width: 650px;
          font-family: "Inconsolata";
          font-optical-sizing: auto;
          font-weight: <weight>;
          font-style: normal;
          font-variation-settings:
      }
      
      #maincontent { 
        max-width:42em;margin:15 auto; 
      }
    </style>	
    </head>
    
    
    <body>
    <div id="maincontent" style="margin-top:70px">
    <h2 style="margin-bottom:10px;">Openseal AI</h2>
    <div style="margin-bottom:40px;">The Safe AI Operating System</div>
    <p>Intelligent, private, sealed AI stack for everyone - built in the <i>open</i>.</p>
    <p style="margin-bottom: 40px"><i>Update: We're raising.
      Reach out to us at <a href="mailto:hello@openseal.ai">hello@openseal.ai</a> for more info.</i>
    </p>
    <p>Julien Lauret, Angelica Handover and Prasanna Loganathar</p>
    <p>Oct 15, 2024</p>
    
    
    </div></body></html>`;

    return new Response(html, {
      status: 200,
      headers: { "content-type": "text/html" },
    });
  },
};
