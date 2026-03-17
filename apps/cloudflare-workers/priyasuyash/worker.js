/**
 * Welcome to Cloudflare Workers! This is your first worker.
 *
 * - Run `npm run dev` in your terminal to start a development server
 * - Open a browser tab at http://localhost:8787/ to see your worker in action
 * - Run `npm run deploy` to publish your worker
 *
 * Learn more at https://developers.cloudflare.com/workers/
 */

const baseUrl = "https://priyasuyash.com";
const goUrl = `${baseUrl}/go`;
const joinUrl = `${baseUrl}/join`;

const newBaseUrl = "https://priyashfeb12.wixsite.com/my-site-3-copy";
const rsvpUrl = `${newBaseUrl}/events/pre-wedding-wedding-celebrations/form`;
const gAlbumUrl = "https://photos.app.goo.gl/5mBkf2bhk1kcwZNm8";
const myRegistryUrl = "https://www.myregistry.com/giftlist/suyashandpriya";
const giftRegistryUrl =
  "https://www.myregistry.com/wedding-registry/priya-loganathar-and-suyash-bhatt-monona-wi/3921341/giftlist";
const guestBookUrl =
  "https://www.myregistry.com/Visitors/Guestbook.aspx?RegistryId=3921341";
const zolaUrl = "https://www.zola.com/registry/suyashandpriya";

const gCalUrl =
  "https://calendar.google.com/calendar/render?action=TEMPLATE&dates=20240209T183000Z%2F20240211T183000Z&details=Priya%20-%20Suyash%20Wedding&location=https%3A%2F%2Fmaps.app.goo.gl%2FesXekjG3TijoGM3J7&text=Priya%20-%20Suyash%20Wedding";
const gMapsUrl = "https://maps.app.goo.gl/esXekjG3TijoGM3J7";
const gSharedCal =
  "https://calendar.google.com/calendar/u/0?cid=Y185NTZkNjUzZmJmZGJhZDU3MDVmNWUzZmY4ZjU4OGRmNjk3YzhlMjE5NmJmZjcyODE2Yjc5ZjAxNzVhMjc4OTcyQGdyb3VwLmNhbGVuZGFyLmdvb2dsZS5jb20";

const imgBucket = "https://pub-cf2bc529bdb841a1bc78556f49c8f1d9.r2.dev";
const priyaImg = `${imgBucket}/priya-suyash.jpg`;
const dogsImg = `${imgBucket}/buddy-jil-cropped.jpeg`;

function generatePathMaps(hasSenseOfHomour) {
  const indexUrl = hasSenseOfHomour ? goUrl : joinUrl;
  return [
    { n: "rsvp", r: /\/rsvp\/?$/, target: rsvpUrl },
    { n: "album", r: /\/album\/?$/, target: gAlbumUrl },
    { n: "a", r: /\/a\/?$/, target: gAlbumUrl },
    { n: "gifts", r: /\/gifts\/?$/, target: giftRegistryUrl },
    { n: "gift", r: /\/gift\/?$/, target: giftRegistryUrl },
    { n: "g", r: /\/g\/?$/, target: giftRegistryUrl },
    { n: "guestbook", r: /\/guestbook\/?$/, target: guestBookUrl },
    { n: "b", r: /\/b\/?$/, target: guestBookUrl },
    { n: "registry", r: /\/registry\/?$/, target: myRegistryUrl },
    { n: "r", r: /\/r\/?$/, target: myRegistryUrl },
    { n: "zola", r: /\/zola\/?$/, target: zolaUrl },
    { n: "z", r: /\/z\/?$/, target: zolaUrl },
    { n: "index", r: /\index\/?$/, target: indexUrl },
    { n: hasSenseOfHomour ? "go" : "join", r: /\/go\/?$/, target: indexUrl },
  ];
}

function generateProgramSchedule() {
  return [
    {
      date: "2024-02-11",
      items: [
        { when: "9am", item: "ganesh pooja", where: "ballroom" },
        { when: "10am", item: "haldi", where: "lawn by the beach" },
        { when: "12-4pm", item: "mehendi", where: "main lawn" },
        { when: "7pm", item: "sangeet", where: "ballroom" },
      ],
    },
    {
      date: "2024-02-12",
      items: [
        { when: "9am", item: "nalangu", where: "taj deck" },
        { when: "9.30-10.30am", item: "engagement", where: "taj deck" },
        { when: "4pm", item: "baraat", where: "main portico" },
        { when: "5.45pm", item: "wedding", where: "main lawn" },
        { when: "8pm", item: "reception", where: "main lawn" },
      ],
    },
  ];
}

function generateGoHtml(hasSenseOfHomour = false) {
  let linksObj = new Map();
  const pathMaps = generatePathMaps(hasSenseOfHomour);
  const programSchedule = generateProgramSchedule();

  linksObj.set("home", newBaseUrl);
  for (const o of pathMaps) {
    linksObj.set(o.n, o.target);
  }

  let prevCategory = "";
  const linksText = [...linksObj.entries()]
    .map(([k, v]) => {
      const lnk = `<li class="link-block"> 
          <a href="${baseUrl}/${k}">${baseUrl}${k !== "home" ? "/" + k : ""}</a>
          </li>`;
      if (prevCategory == v) {
        return lnk;
      }
      prevCategory = v;
      return `<li class="dot-block"><b>${k}</b></li>${lnk}`;
    })
    .reduce((prev, curr) => prev + curr);

  const programLine = (x) =>
    `<li class="dot-line">
      <b class="time">${x.when}</b>: 
      <span class="item">${x.item}</span> @ 
      <span class="location">${x.where}</span>
    </li>`;
  const progScheduleLines = (x) =>
    `<li class="dot-block">
    <b class="date">${x.date}</b>
    <ul class="prog-line">${x.items.map(programLine).join("")}</ul>
    </li>`;
  const programText = `<b>program</b> - <a href="${gSharedCal}">calendar</a>
  <ul class="prog-block">${
    programSchedule.map(progScheduleLines).join("")
  }</ul>`;

  const smoothTransition = (time) => `all ${time} ease-out`;
  const smoothTransitionsAll = (time) =>
    ["-webkit-transition", "-moz-transition", "transition"]
      .map((x) => `${x}: ${smoothTransition(time)}`).join(";\n");

  const styles = `<style>
  body {
    font-family: system-ui, sans-serif;
    font-weight: 300;
    padding: 30px 20px;
    color: #3b3b3b;
    max-width: 450px;
    margin: 0 auto;
  }
  .ul-simple {
    list-style-type:none;
  }
  .banner-img-wrap {
  }
  .banner-img {
    width: 100%;
    height: 100%;
    max-height: 250px;
    border-radius: 5px;
    background: url(${priyaImg}) center center / cover no-repeat;
    ${smoothTransitionsAll("1.4s")};
  }
  .banner-img-2 {
    background: url(${dogsImg}) center center / cover no-repeat;
  }
  .banner-text {
    padding: 10px 0 0 0;
  }
  .banner-text-line {
    padding: 0 0 4px 0;
  }
  .dot-block {
    padding: 4px 0 4px 4px;
  }
  .link-block {
    padding: 2px 0 2px 50px;
  }
  .dot-line {
    padding: 2px 0 0px 0;
  }
  .prog-line {
    margin: 2px;
    padding: 0 0 0 12px;
  }
  .prog-block {
    padding: 0 0 0 38px;
  }
  b, h3 {
    font-weight: 500;
  }
  .prog-block .date {
    font-weight: 500;
  }
  .prog-block .time {
    font-weight: 400;
  }
  .prog-block .item {
    font-weight: 500;
  }
  .prog-block .location {
    font-weight: 300;
  }
  a {
    text-decoration: none;
    font-weight: 400;
  }
  .smiley {
    font-weight: 400;
    margin: 20px 50% 20px 50%;
    transform: rotate(90deg);
  }
  h3 {
    line-height: 150%;
  }
  .head-wrapper {
    display: block;
    position: relative;
    height: 90px;
  }
  .head-wrapper h3 {
    position: absolute; 
    top: 0;
    opacity: 0;
    ${smoothTransitionsAll("0.8s")};
  }
  .head-show {
    opacity: 1 !important;
  }
  </style>`;

  const js = `<script>
    let imgLoadHit = 0;
    let hoverTriggerHandle = 0;
    const hasSenseOfHumor = ${hasSenseOfHomour};

    function setImgTrigger(delay) {
      if (hoverTriggerHandle) return;
      hoverTriggerHandle = setTimeout(() => {
        hoverTriggerHandle = 0;
        imgSwitch();
      }, delay);
    }

    function imgLoad() {
      imgLoadHit++;
      if (imgLoadHit == 2) {
        setImgTrigger(3800);
      }
    }

    function imgSwitch() {
      if (!hasSenseOfHumor) return;
      if (imgLoadHit < 2) return;
      if (hoverTriggerHandle) return;
      const e = document.querySelector(".banner-img");
      const img2Class = "banner-img-2";
      const headShowClass = "head-show";

      let cl = e.classList;

      let els = document.querySelectorAll(".head-item");
      els = Array.from(els);

      if (cl.contains(img2Class)) {
        cl.remove(img2Class);
        els[1].classList.remove(headShowClass);
        els[0].classList.add(headShowClass);
        setImgTrigger(4500);
      } else {
        cl.add(img2Class);
        els[1].classList.add(headShowClass);
        els[0].classList.remove(headShowClass);
        setImgTrigger(6500);
      }
    }

  </script>`;

  const inviteLine = hasSenseOfHomour
    ? "hi there! you're joyfully invited; <br>probabilistically.. may-be."
    : "hi there! you're joyfully invited; please come join us for the celebrations :)";

  const html = `<title>Priya - Suyash Wedding</title>
              <meta name="viewport" content="width=device-width, user-scalable=yes"/>
              ${styles}
              ${js}
              ${
    [priyaImg, dogsImg].map((x) =>
      `<link rel="preload" as="image" onload="imgLoad()" href="${x}">`
    ).join("")
  }
              <body>
              <div class="head-wrapper">
              <h3 class="head-item head-show">${inviteLine}</h3>
              <h3 class="head-item">subject to approval of our board members; plausibly..</h3>
              </div>
              <div class="banner-img-wrap" onclick="imgSwitch()">
                <img class="banner-img">
              </div>
              <ul class="ul-simple banner-text">
              <li class="banner-text-line"><b>when</b>: <a href="${gCalUrl}">10 - 12th feb, 2024</a></li>
              <li class="banner-text-line"><b>where</b>: <a href="${gMapsUrl}">kaldan samudhra palace</a></li>
              </ul>
              <div>${programText}</div>
              <div>${linksText}</div>
              <div class="smiley">:)</div>
              </body>`;

  return html;
}

const goHtml = generateGoHtml(true);
const joinHtml = generateGoHtml(false);

function handleGo(hasSenseOfHomour) {
  return new Response(hasSenseOfHomour ? goHtml : joinHtml, {
    status: 200,
    headers: { "content-type": "text/html" },
  });
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    if (url.pathname == "/go") {
      return handleGo(true);
    }

    if (url.pathname == "/join") {
      return handleGo(false);
    }

    const cMaps = [
      ...generatePathMaps(false),
      { n: "dog", r: /\/dog\/?$/, target: goUrl },
      { n: "dog-invite", r: /\/dog-invite\/?$/, target: goUrl },
      { d: "/debug/now", json: new Date() },
    ];

    for (const o of cMaps) {
      if (o.r && o.r.test(url.pathname)) {
        return Response.redirect(o.target);
      }
      if (o.d && o.d == url.pathname) {
        return Response.json(o.json);
      }
    }
    return handleGo(true);
    // return Response.redirect(newBaseUrl);
  },
};
