const uiVersion = new URL(import.meta.url).searchParams.get("v") ?? "dev";
const versioned = (path) => `${path}?v=${encodeURIComponent(uiVersion)}`;
const {appLinks} = await import(versioned("/pkg/app-links-data.js"));

const metadata = new Map(appLinks.map((app) => [app.name, app]));
const metadataByDisplayName = new Map(appLinks.map((app) => [normalizeText(app.displayName), app]));
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

function appFromColumn(column) {
    const image = column.querySelector("img.oauth2-img[id], img[id]");
    const idMatch = appFromId(image?.id);
    if (idMatch) return idMatch;

    const linkedElement = column.querySelector("[href]");
    const hrefMatch = appFromHref(linkedElement?.getAttribute("href") ?? "");
    if (hrefMatch) return hrefMatch;

    return appFromText(column);
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

function sortAppLinks() {
    const rows = document.querySelectorAll("main .row");
    for (const row of rows) {
        if (row.closest(".abird-app-group")) continue;

        const columns = Array.from(row.children)
            .map((column, index) => {
                const app = appFromColumn(column);
                if (!app) return null;
                const group = appGroup(app);
                column.dataset.appGroup = group;
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
