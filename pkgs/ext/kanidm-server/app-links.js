const uiVersion = new URL(import.meta.url).searchParams.get("v") ?? "dev";
const versioned = (path) => `${path}?v=${encodeURIComponent(uiVersion)}`;
const cacheBusted = (path) => `${versioned(path)}&refresh=${Date.now()}`;
const appLinksDataPath = "/pkg/app-links-data.js";
const appLinksData = await import(versioned(appLinksDataPath));

let appLinks = [];
let metadata = new Map();
let metadataByDisplayName = new Map();
const groupOrder = [
    {id: "core", label: "Core"},
    {id: "office", label: "Office"},
    {id: "productivity", label: "Productivity"},
    {id: "infra", label: "Infra"},
    {id: "dev", label: "Dev"},
    {id: "others", label: "Others"},
];
const groupMetadata = new Map(groupOrder.map((group, index) => [group.id, {...group, index}]));
const defaultGroup = "others";
let metadataRefreshAttempted = false;

function setAppLinks(nextAppLinks) {
    appLinks = Array.isArray(nextAppLinks) ? nextAppLinks : [];
    metadata = new Map(appLinks.map((app) => [app.name, app]));
    metadataByDisplayName = new Map(appLinks.map((app) => [normalizeText(app.displayName), app]));
}

setAppLinks(appLinksData.appLinks);

function normalizeText(value) {
    return String(value ?? "").trim().replace(/\s+/g, " ").toLowerCase();
}

function appSortValue(app, fallbackIndex) {
    const order = Number(app?.ui?.order);
    return Number.isFinite(order) ? order : 100000 + fallbackIndex;
}

function appGroup(app) {
    const group = app?.ui?.group;
    return groupMetadata.has(group) ? group : defaultGroup;
}

function cssToken(value) {
    return String(value ?? "")
        .trim()
        .toLowerCase()
        .replace(/[^a-z0-9]+/g, "-")
        .replace(/^-+|-+$/g, "");
}

function appIconClassNames(app) {
    const icon = app?.ui?.icon;
    if (!icon || typeof icon !== "object" || Array.isArray(icon)) return [];

    const surface = cssToken(icon.surface);
    return surface ? [`abird-app-icon-surface-${surface}`] : [];
}

function applyAppPresentation(column, app) {
    for (const className of Array.from(column.classList)) {
        if (className.startsWith("abird-app-icon-")) {
            column.classList.remove(className);
        }
    }

    const iconClassNames = appIconClassNames(app);
    if (iconClassNames.length > 0) {
        column.classList.add(...iconClassNames);
    }
}

function appFromId(id) {
    if (!id) return null;
    return metadata.get(id) ?? null;
}

function appFromHref(href) {
    if (!href) return null;

    for (const app of appLinks) {
        if (href.includes(`/oauth2/openid/${app.name}`) || href.includes(`/ui/oauth2/${app.name}`)) {
            return app;
        }
    }
    return null;
}

function appFromText(container) {
    const textElements = container.querySelectorAll("a, span, p, h1, h2, h3, h4, h5, h6, div");
    for (const element of textElements) {
        const app = metadataByDisplayName.get(normalizeText(element.textContent));
        if (app) return app;
    }

    return metadataByDisplayName.get(normalizeText(container.textContent)) ?? null;
}

function appColumnFallback(column, fallbackIndex) {
    const image = column.querySelector("img.oauth2-img[id], img[id]");
    const displayName =
        column.querySelector("label")?.textContent ??
        column.querySelector("a, span, p, h1, h2, h3, h4, h5, h6, div")?.textContent ??
        column.textContent;
    const normalizedDisplayName = String(displayName ?? "").trim();

    return {
        name: image?.id || normalizedDisplayName || `unknown-${fallbackIndex}`,
        displayName: normalizedDisplayName,
        ui: {
            group: defaultGroup,
            order: 100000 + fallbackIndex,
        },
    };
}

function isAppColumn(column) {
    if (column.querySelector("img.oauth2-img[id], img[id]")) return true;

    const linkedElement = column.querySelector("[href]");
    const href = linkedElement?.getAttribute("href") ?? "";
    return href.includes("/oauth2/openid/") || href.includes("/ui/oauth2/");
}

function appFromColumn(column) {
    const image = column.querySelector("img.oauth2-img[id], img[id]");
    const idMatch = appFromId(image?.id);
    if (idMatch) return idMatch;

    const linkedElement = column.querySelector("[href]");
    const hrefMatch = appFromHref(linkedElement?.getAttribute("href") ?? "");
    if (hrefMatch) return hrefMatch;

    return appFromText(column);
}

function unknownAppColumns() {
    return Array.from(document.querySelectorAll("main .row"))
        .filter((row) => !row.closest(".abird-app-group"))
        .flatMap((row) => Array.from(row.children))
        .filter((column) => isAppColumn(column) && !appFromColumn(column));
}

async function refreshMetadataForUnknownApps() {
    if (metadataRefreshAttempted || unknownAppColumns().length === 0) return false;
    metadataRefreshAttempted = true;

    try {
        const freshData = await import(cacheBusted(appLinksDataPath));
        setAppLinks(freshData.appLinks);
        return true;
    } catch (err) {
        console.error("Failed to refresh Abird app links metadata", err);
        return false;
    }
}

function createGroupSection(groupId, rowClassName) {
    const group = groupMetadata.get(groupId) ?? groupMetadata.get(defaultGroup);
    const section = document.createElement("section");
    section.className = "abird-app-group";
    section.dataset.appGroup = group.id;

    const title = document.createElement("h2");
    title.className = "abird-app-group-title";
    title.textContent = group.label;

    const row = document.createElement("div");
    row.className = rowClassName;
    row.classList.add("abird-app-group-row");

    section.append(title, row);
    return {row, section};
}

function markAppLinksReady() {
    document.body.classList.add("abird-app-links-ready");
}

async function sortAppLinks() {
    if (await refreshMetadataForUnknownApps()) {
        sortAppLinks();
        return;
    }

    const rows = document.querySelectorAll("main .row");
    for (const row of rows) {
        if (row.closest(".abird-app-group")) continue;

        const columns = Array.from(row.children)
            .map((column, index) => {
                const app = appFromColumn(column) ?? (isAppColumn(column) ? appColumnFallback(column, index) : null);
                if (!app) return null;
                const group = appGroup(app);
                column.dataset.appGroup = group;
                applyAppPresentation(column, app);
                return {
                    app,
                    column,
                    group,
                    index,
                    order: appSortValue(app, index),
                };
            })
            .filter(Boolean);
        if (columns.length === 0) continue;

        const sortedColumns = columns
            .sort((left, right) => {
                const leftGroup = groupMetadata.get(left.group);
                const rightGroup = groupMetadata.get(right.group);
                if (leftGroup.index !== rightGroup.index) return leftGroup.index - rightGroup.index;
                if (left.order !== right.order) return left.order - right.order;
                return left.app.name.localeCompare(right.app.name);
            });

        const sections = new Map();
        for (const {column, group} of sortedColumns) {
            if (!sections.has(group)) {
                sections.set(group, createGroupSection(group, row.className));
            }
            sections.get(group).row.appendChild(column);
        }

        for (const {section} of sections.values()) {
            row.parentNode.insertBefore(section, row);
        }
        row.remove();
    }

    markAppLinksReady();
}

if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", sortAppLinks, {once: true});
} else {
    sortAppLinks();
}

document.body.addEventListener("htmx:afterOnLoad", () => {
    document.body.classList.remove("abird-app-links-ready");
    sortAppLinks();
});
