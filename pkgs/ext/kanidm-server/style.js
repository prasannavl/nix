/**  Queries the user's preferred colour scheme and returns the appropriate value.
 From https://getbootstrap.com/docs/5.3/customize/color-modes/#javascript
*/
function getPreferredTheme() {
  return window.matchMedia("(prefers-color-scheme: dark)").matches
    ? "dark"
    : "light";
}

/**  Sets the theme.
 */
function updateColourScheme() {
  const theme = getPreferredTheme();
  console.debug(`updateColourScheme theme->${theme}`);
  document.documentElement.setAttribute("data-bs-theme", theme);
}

updateColourScheme();
window.matchMedia("(prefers-color-scheme: light)").addEventListener(
  "change",
  updateColourScheme,
);
window.matchMedia("(prefers-color-scheme: dark)").addEventListener(
  "change",
  updateColourScheme,
);
document.body.addEventListener("htmx:afterOnLoad", updateColourScheme);

const abirdUiVersion = "@abirdUiVersion@";
const abirdVersioned = (path) =>
  `${path}?v=${encodeURIComponent(abirdUiVersion)}`;

function installAbirdOverrideStyles() {
  if (document.getElementById("abird-override-style")) {
    return;
  }

  const link = document.createElement("link");
  link.id = "abird-override-style";
  link.rel = "stylesheet";
  link.href = abirdVersioned("/pkg/override.css");
  document.head.append(link);
}

installAbirdOverrideStyles();

import(abirdVersioned("/pkg/app-links.js"))
  .catch((err) => {
    console.error("Failed to load Abird app links UI", err);
    document.body.classList.add("abird-app-links-ready");
  });

import(abirdVersioned("/pkg/app-passwords.js")).catch((err) => {
  console.error("Failed to load Abird app passwords UI", err);
});
