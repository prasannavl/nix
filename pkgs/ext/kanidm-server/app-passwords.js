(() => {
    const pageHash = "#app-passwords";

    function isProfilePage() {
        return window.location.pathname.startsWith("/ui/profile")
            || window.location.pathname === "/ui/update_credentials"
            || window.location.pathname === "/ui/enrol"
            || window.location.pathname === "/ui/radius"
            || document.querySelector(".side-menu") !== null;
    }

    function node(tag, attrs = {}, children = []) {
        const el = document.createElement(tag);
        Object.entries(attrs).forEach(([key, value]) => {
            if (value === null || value === undefined) {
                return;
            }
            if (key === "class") {
                el.className = value;
            } else if (key === "text") {
                el.textContent = value;
            } else {
                el.setAttribute(key, value);
            }
        });
        children.forEach((child) => {
            el.append(child instanceof Node ? child : document.createTextNode(child));
        });
        return el;
    }

    function normalizeText(value) {
        return String(value ?? "").trim().replace(/\s+/g, " ").toLowerCase();
    }

    async function requestJson(url, options = {}) {
        const response = await fetch(url, {
            credentials: "include",
            headers: {
                accept: "application/json",
                ...(options.headers || {}),
            },
            ...options,
        });

        if (!response.ok) {
            const body = await response.text();
            throw new Error(`${response.status} ${body || response.statusText}`);
        }

        if (response.status === 204) {
            return null;
        }

        return response.json();
    }

    function setMessage(target, message, level = "info") {
        target.replaceChildren(node("div", {
            class: `alert alert-${level}`,
            role: "alert",
            text: message,
        }));
    }

    function applicationById(applicationId, applications) {
        return applications.find((item) => item.id === applicationId);
    }

    function applicationName(applicationId, applications) {
        const app = applicationById(applicationId, applications);
        return app?.displayname || app?.displayName || app?.name || applicationId;
    }

    function applicationBindName(applicationId, applications) {
        const app = applicationById(applicationId, applications);
        return app?.name || applicationId;
    }

    function sortValue(password, key, applications) {
        if (key === "application") {
            return applicationName(password.applicationUuid, applications);
        }
        if (key === "uuid") {
            return password.uuid || "";
        }
        return password.label || "";
    }

    function compareValues(left, right) {
        return String(left).localeCompare(String(right), undefined, {
            numeric: true,
            sensitivity: "base",
        });
    }

    function sortedPasswords(passwords, applications, sortState) {
        return [...passwords].sort((left, right) => {
            const result = compareValues(
                sortValue(left, sortState.key, applications),
                sortValue(right, sortState.key, applications),
            );
            if (result !== 0) {
                return sortState.direction === "asc" ? result : -result;
            }

            return compareValues(left.uuid || "", right.uuid || "");
        });
    }

    function escapeRegExp(value) {
        return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    }

    function slugPart(value) {
        return String(value)
            .toLowerCase()
            .replace(/[^a-z0-9]+/g, "-")
            .replace(/^-+|-+$/g, "");
    }

    function labelBase(applicationId, applications) {
        return `${slugPart(applicationBindName(applicationId, applications)) || "app"}-device`;
    }

    function nextDefaultLabel(applicationId, applications, passwords) {
        const base = labelBase(applicationId, applications);
        const pattern = new RegExp(`^${escapeRegExp(base)}-(\\d+)$`);
        const highest = passwords.reduce((max, password) => {
            const match = pattern.exec(password.label || "");
            if (!match) {
                return max;
            }

            return Math.max(max, Number(match[1]));
        }, 0);

        return `${base}-${highest + 1}`;
    }

    function renderSortHeader(title, key, sortState, onSort) {
        const indicator = sortState.key === key
            ? (sortState.direction === "asc" ? " ^" : " v")
            : "";

        const button = node("button", {
            class: "btn btn-link p-0 text-decoration-none",
            type: "button",
            text: `${title}${indicator}`,
        });
        button.addEventListener("click", () => onSort(key));
        return node("th", {scope: "col"}, [button]);
    }

    function renderMobileSortButton(title, key, sortState, onSort) {
        const active = sortState.key === key;
        const button = node("button", {
            class: `btn btn-sm ${active ? "btn-primary" : "btn-outline-secondary"}`,
            type: "button",
            text: `${title}${active ? (sortState.direction === "asc" ? " ^" : " v") : ""}`,
        });
        button.addEventListener("click", () => onSort(key));
        return button;
    }

    function renderMobileSortControls(sortState, onSort) {
        return node("div", {class: "d-xl-none mb-2"}, [
            node("div", {class: "form-label mb-2", text: "Sort by"}),
            node("div", {class: "d-flex flex-wrap gap-2"}, [
                renderMobileSortButton("Label", "label", sortState, onSort),
                renderMobileSortButton("App", "application", sortState, onSort),
                renderMobileSortButton("ID", "uuid", sortState, onSort),
            ]),
        ]);
    }

    function purposeVariant(purpose, variant) {
        if (!purpose || typeof purpose !== "object" || Array.isArray(purpose)) {
            return undefined;
        }

        const key = Object.keys(purpose).find((item) => item.toLowerCase() === variant);
        return key ? purpose[key] : undefined;
    }

    function sessionWriteState(uat) {
        const purpose = uat?.purpose;
        if (typeof purpose === "string") {
            const normalized = purpose.toLowerCase();
            return {
                canUnlock: normalized === "privilegecapable",
                writable: normalized === "readwrite",
            };
        }

        const readwrite = purposeVariant(purpose, "readwrite");
        if (readwrite === undefined) {
            return {canUnlock: false, writable: false};
        }

        const expiry = readwrite?.expiry;
        if (expiry === null || expiry === undefined) {
            return {canUnlock: true, writable: false};
        }

        const expiryMs = Number(expiry) * 1000;
        if (!Number.isFinite(expiryMs)) {
            return {canUnlock: true, writable: false};
        }

        return {
            canUnlock: true,
            writable: Date.now() < expiryMs,
        };
    }

    function renderUnlockPrompt() {
        return node("div", {
            class: "alert alert-warning d-flex flex-column flex-sm-row align-items-sm-center justify-content-between gap-3",
            role: "alert",
        }, [
            node("div", {
                text: "This session is read-only. Unlock edits before changing app passwords.",
            }),
            node("a", {
                class: "btn btn-warning text-nowrap",
                href: "/ui/unlock",
                text: "Unlock",
            }),
        ]);
    }

    function getCurrentAccountId(whoami) {
        return whoami?.youare?.attrs?.name?.[0] || whoami?.youare?.attrs?.spn?.[0]?.split("@")?.[0];
    }

    function getApplicationPasswords(person) {
        return person?.application_password || person?.applicationPassword || [];
    }

    function goToAppPasswords() {
        if (window.location.pathname.startsWith("/ui/profile")) {
            window.history.pushState(null, "", "/ui/profile#app-passwords");
            renderAppPasswords();
        } else {
            window.location.assign("/ui/profile#app-passwords");
        }
    }

    function profileContentTarget() {
        const settingsWindow = document.querySelector("#settings-window");
        if (settingsWindow) {
            return settingsWindow;
        }

        const sideMenu = document.querySelector(".side-menu");
        if (sideMenu?.parentElement) {
            const sibling = [...sideMenu.parentElement.children].find((child) => {
                return child !== sideMenu && !child.contains(sideMenu);
            });
            if (sibling) {
                return sibling;
            }
        }

        return document.querySelector("main");
    }

    function renderExistingPasswords(
        target,
        accountId,
        applications,
        passwords,
        sortState,
        onSort,
        refresh,
        regenerate,
        sessionWritable,
    ) {
        const orderedPasswords = sortedPasswords(passwords, applications, sortState);

        if (!orderedPasswords.length) {
            target.replaceChildren(node("p", {
                class: "text-body-secondary",
                text: "No application passwords are visible for this account.",
            }));
            return;
        }

        function renderPasswordActions(password) {
            const regenerateButton = node("button", {
                class: "btn btn-sm btn-outline-primary",
                type: "button",
                text: "Regenerate",
            });
            const deleteButton = node("button", {
                class: "btn btn-sm btn-outline-danger",
                type: "button",
                text: "Delete",
            });
            regenerateButton.disabled = !sessionWritable;
            deleteButton.disabled = !sessionWritable;
            regenerateButton.addEventListener("click", async () => {
                if (!window.confirm(`Regenerate application password "${password.label}"? The old password will stop working immediately.`)) {
                    return;
                }
                regenerateButton.disabled = true;
                deleteButton.disabled = true;
                try {
                    await regenerate(password);
                } catch (err) {
                    regenerateButton.disabled = false;
                    deleteButton.disabled = false;
                    window.alert(`Failed to regenerate application password: ${err.message}`);
                }
            });
            deleteButton.addEventListener("click", async () => {
                if (!window.confirm(`Delete application password "${password.label}"?`)) {
                    return;
                }
                deleteButton.disabled = true;
                regenerateButton.disabled = true;
                try {
                    await requestJson(`/scim/v1/Person/${encodeURIComponent(accountId)}/Application/${encodeURIComponent(password.uuid)}`, {
                        method: "DELETE",
                    });
                    await refresh();
                } catch (err) {
                    deleteButton.disabled = false;
                    regenerateButton.disabled = false;
                    window.alert(`Failed to delete application password: ${err.message}`);
                }
            });

            return node("div", {class: "d-flex flex-wrap gap-2 justify-content-start justify-content-md-end"}, [
                regenerateButton,
                deleteButton,
            ]);
        }

        function renderPasswordField(label, value, valueClass = "") {
            return node("div", {class: "py-2"}, [
                node("div", {class: "small text-body-secondary mb-1", text: label}),
                node("div", {class: `text-break ${valueClass}`.trim(), text: value}),
            ]);
        }

        const tbody = node("tbody");
        orderedPasswords.forEach((password) => {
            tbody.append(node("tr", {}, [
                node("td", {text: password.label}),
                node("td", {text: applicationName(password.applicationUuid, applications)}),
                node("td", {class: "font-monospace small text-break", text: password.uuid}),
                node("td", {class: "text-end"}, [
                    renderPasswordActions(password),
                ]),
            ]));
        });

        const mobileCards = node("div", {class: "d-xl-none"}, orderedPasswords.map((password) => {
            return node("div", {class: "border-top py-3"}, [
                node("div", {class: "row g-2"}, [
                    node("div", {class: "col-12 col-sm-6"}, [
                        renderPasswordField("Label", password.label, "fw-semibold"),
                    ]),
                    node("div", {class: "col-12 col-sm-6"}, [
                        renderPasswordField("Application", applicationName(password.applicationUuid, applications)),
                    ]),
                    node("div", {class: "col-12"}, [
                        renderPasswordField("Password ID", password.uuid, "font-monospace small"),
                    ]),
                ]),
                node("div", {class: "mt-2"}, [renderPasswordActions(password)]),
            ]);
        }));

        target.replaceChildren(
            renderMobileSortControls(sortState, onSort),
            mobileCards,
            node("div", {class: "table-responsive d-none d-xl-block"}, [
                node("table", {class: "table align-middle mb-0"}, [
                    node("thead", {}, [
                        node("tr", {}, [
                            renderSortHeader("Label", "label", sortState, onSort),
                            renderSortHeader("Application", "application", sortState, onSort),
                            renderSortHeader("Password ID", "uuid", sortState, onSort),
                            node("th", {scope: "col", class: "text-end", text: ""}),
                        ]),
                    ]),
                    tbody,
                ]),
            ]),
        );
    }

    async function renderAppPasswords() {
        const settingsWindow = profileContentTarget();
        if (!settingsWindow) {
            return;
        }

        settingsWindow.replaceChildren(
            node("div", {}, [node("h2", {text: "App Passwords"})]),
            node("hr"),
            node("div", {id: "abird-app-passwords"}),
        );

        document.querySelectorAll(".side-menu-item").forEach((item) => {
            item.classList.toggle("active", item.dataset.abirdAppPasswords === "true");
        });

        const root = document.querySelector("#abird-app-passwords");
        setMessage(root, "Loading application password settings...");

        let whoami;
        let applications;
        let uat;
        let accountId;

        try {
            [whoami, applications, uat] = await Promise.all([
                requestJson("/v1/self"),
                requestJson("/scim/v1/Application"),
                requestJson("/v1/self/_uat"),
            ]);
            accountId = getCurrentAccountId(whoami);
            if (!accountId) {
                throw new Error("Unable to determine the current account name.");
            }
        } catch (err) {
            setMessage(root, `Unable to load application password settings: ${err.message}`, "danger");
            return;
        }

        const applicationList = applications.resources || [];
        if (!applicationList.length) {
            setMessage(root, "No applications are available for application passwords.", "warning");
            return;
        }

        const status = node("div");
        const existingPasswords = node("div");
        const labelInput = node("input", {
            class: "form-control",
            id: "abird-app-password-label",
            maxlength: "64",
            type: "text",
        });
        const appSelect = node("select", {
            class: "form-select",
            id: "abird-app-password-application",
        });
        applicationList.forEach((app) => {
            appSelect.append(node("option", {
                value: app.id,
                text: app.displayname || app.displayName || app.name || app.id,
            }));
        });

        const generateButton = node("button", {
            class: "btn btn-primary text-nowrap",
            type: "button",
            text: "Generate Password",
        });
        let visiblePasswords = [];
        const writeState = sessionWriteState(uat);
        let currentDefaultLabel = "";
        let labelTouched = false;
        let sortState = {
            key: "label",
            direction: "asc",
        };

        function updateDefaultLabel(force = false) {
            const nextLabel = nextDefaultLabel(appSelect.value, applicationList, visiblePasswords);
            const previousDefaultLabel = currentDefaultLabel;
            currentDefaultLabel = nextLabel;
            labelInput.placeholder = nextLabel;

            if (force || !labelTouched || labelInput.value.trim() === "" || labelInput.value === previousDefaultLabel) {
                labelInput.value = nextLabel;
                labelTouched = false;
            }
        }

        function renderPasswordList() {
            renderExistingPasswords(
                existingPasswords,
                accountId,
                applicationList,
                visiblePasswords,
                sortState,
                (key) => {
                    sortState = {
                        key,
                        direction: sortState.key === key && sortState.direction === "asc" ? "desc" : "asc",
                    };
                    renderPasswordList();
                },
                refreshExistingPasswords,
                regenerateApplicationPassword,
                writeState.writable,
            );
        }

        root.replaceChildren(
            ...(!writeState.writable && writeState.canUnlock ? [renderUnlockPrompt()] : []),
            node("div", {class: "mb-4"}, [
                node("p", {
                    class: "text-body-secondary mb-2",
                    text: "App passwords are compatibility credentials for apps that do not yet support passkeys.",
                }),
                node("ul", {class: "text-body-secondary ps-4 mb-3"}, [
                    node("li", {text: "Less secure than passkeys."}),
                    node("li", {text: "Use one password per device."}),
                    node("li", {text: "Do not reuse passwords across devices."}),
                    node("li", {text: "Regenerate anytime you need a replacement."}),
                ]),
                node("form", {class: "row gy-3"}, [
                    node("div", {class: "col-12 col-lg-6"}, [
                        node("label", {
                            class: "form-label",
                            for: "abird-app-password-application",
                            text: "Application",
                        }),
                        appSelect,
                    ]),
                    node("div", {class: "col-12 col-lg-6"}, [
                        node("label", {
                            class: "form-label",
                            for: "abird-app-password-label",
                            text: "Label",
                        }),
                        labelInput,
                    ]),
                    node("div", {class: "col-12 d-flex justify-content-end"}, [generateButton]),
                ]),
            ]),
            status,
            node("h3", {class: "h5 mt-4", text: "Existing Passwords"}),
            existingPasswords,
        );

        generateButton.disabled = !writeState.writable;

        labelInput.addEventListener("input", () => {
            labelTouched = labelInput.value.trim() !== "" && labelInput.value !== currentDefaultLabel;
        });

        appSelect.addEventListener("change", () => {
            updateDefaultLabel();
        });

        async function createApplicationPassword(applicationUuid, label) {
            return requestJson(`/scim/v1/Person/${encodeURIComponent(accountId)}/Application/_create_password`, {
                method: "POST",
                headers: {"content-type": "application/json"},
                body: JSON.stringify({
                    applicationUuid,
                    label,
                }),
            });
        }

        function showGeneratedPassword(password, applicationUuid, message) {
            status.replaceChildren(node("div", {class: "alert alert-success", role: "alert"}, [
                node("p", {
                    class: "mb-2",
                    text: message,
                }),
                node("label", {
                    class: "form-label",
                    for: "abird-app-password-secret",
                    text: "Password",
                }),
                node("input", {
                    class: "form-control font-monospace",
                    id: "abird-app-password-secret",
                    readonly: "readonly",
                    type: "text",
                    value: password.secret,
                }),
                node("div", {
                    class: "form-text",
                    text: `Bind DN: name=${accountId},app=${applicationBindName(applicationUuid, applicationList)}`,
                }),
            ]));

            const secretInput = document.querySelector("#abird-app-password-secret");
            secretInput.focus();
            secretInput.select();
        }

        async function regenerateApplicationPassword(password) {
            status.replaceChildren();
            await requestJson(`/scim/v1/Person/${encodeURIComponent(accountId)}/Application/${encodeURIComponent(password.uuid)}`, {
                method: "DELETE",
            });
            const replacement = await createApplicationPassword(password.applicationUuid, password.label);
            showGeneratedPassword(
                replacement,
                password.applicationUuid,
                "Application password regenerated. Copy it now; it will not be shown again.",
            );
            await refreshExistingPasswords();
        }

        async function refreshExistingPasswords() {
            try {
                const person = await requestJson(`/scim/v1/Person/${encodeURIComponent(accountId)}`);
                visiblePasswords = getApplicationPasswords(person);
                updateDefaultLabel();
                renderPasswordList();
            } catch (err) {
                visiblePasswords = [];
                updateDefaultLabel();
                setMessage(existingPasswords, "Existing application passwords are not visible in this session. Generated passwords will still be shown once at creation time.", "secondary");
            }
        }

        generateButton.addEventListener("click", async () => {
            status.replaceChildren();
            generateButton.disabled = true;

            const selectedApplication = appSelect.value;
            const label = labelInput.value.trim() || currentDefaultLabel || labelInput.placeholder;

            try {
                const password = await createApplicationPassword(selectedApplication, label);
                showGeneratedPassword(
                    password,
                    selectedApplication,
                    "Application password created. Copy it now; it will not be shown again.",
                );
                await refreshExistingPasswords();
            } catch (err) {
                const unlockLink = node("a", {
                    href: "/ui/unlock",
                    text: "Unlock profile editing",
                });
                status.replaceChildren(node("div", {class: "alert alert-danger", role: "alert"}, [
                    `Failed to create application password: ${err.message}. `,
                    unlockLink,
                    " and try again if this session is read-only.",
                ]));
            } finally {
                generateButton.disabled = false;
            }
        });

        await refreshExistingPasswords();
    }

    function ensureMenuItem() {
        const sideMenu = document.querySelector(".side-menu");
        if (sideMenu && !sideMenu.querySelector("[data-abird-app-passwords='true']")) {
            const credentials = [...sideMenu.querySelectorAll("a")].find((item) => item.href.endsWith("/ui/update_credentials"));
            const listItem = node("li", {}, [
                node("a", {
                    class: "side-menu-item d-flex rounded link-emphasis",
                    "data-abird-app-passwords": "true",
                    href: "/ui/profile#app-passwords",
                }, [
                    node("div", {class: "icon-container align-items-center justify-content-center d-flex me-2"}, [
                        node("img", {
                            alt: "",
                            class: "text-body-secondary",
                            src: "/pkg/img/icons/key.svg",
                        }),
                    ]),
                    node("div", {text: "App Passwords"}),
                ]),
            ]);

            listItem.querySelector("a").addEventListener("click", (event) => {
                event.preventDefault();
                goToAppPasswords();
            });

            if (credentials?.parentElement) {
                credentials.parentElement.after(listItem);
            } else {
                sideMenu.append(listItem);
            }
        }

        if (!window.matchMedia("(max-width: 767.98px)").matches) {
            return;
        }

        const nav = document.querySelector("nav");
        const profileLink = [...document.querySelectorAll("nav a")].find((item) => {
            return item.href.endsWith("/ui/profile");
        });
        const signOutLink = [...document.querySelectorAll("nav a")].find((item) => {
            return normalizeText(item.textContent) === "sign out" || item.href.endsWith("/ui/logout");
        });
        const referenceLink = profileLink ?? signOutLink;
        if (!nav || !referenceLink || document.querySelector("nav [data-abird-app-passwords='true']")) {
            return;
        }

        const navLink = node("a", {
            class: referenceLink.className,
            "data-abird-app-passwords": "true",
            href: "/ui/profile#app-passwords",
            text: "App Passwords",
        });
        navLink.addEventListener("click", (event) => {
            event.preventDefault();
            goToAppPasswords();
        });

        if (profileLink?.parentElement?.tagName === "LI") {
            profileLink.parentElement.after(node("li", {
                class: profileLink.parentElement.className,
            }, [navLink]));
        } else if (signOutLink?.parentElement?.tagName === "LI") {
            signOutLink.parentElement.before(node("li", {
                class: signOutLink.parentElement.className,
            }, [navLink]));
        } else if (profileLink) {
            profileLink.after(navLink);
        } else if (signOutLink) {
            signOutLink.before(navLink);
        } else {
            nav.append(navLink);
        }
    }

    function reconcileActiveState() {
        document.querySelectorAll("[data-abird-app-passwords='true']").forEach((item) => {
            item.classList.toggle("active", window.location.hash === pageHash);
        });

        document.querySelectorAll(".side-menu-item:not([data-abird-app-passwords='true'])").forEach((item) => {
            if (window.location.hash === pageHash) {
                item.classList.remove("active");
            }
        });
    }

    function reconcile() {
        ensureMenuItem();
        reconcileActiveState();
        if (isProfilePage() && window.location.hash === pageHash) {
            renderAppPasswords();
        }
    }

    window.addEventListener("DOMContentLoaded", reconcile);
    window.addEventListener("load", reconcile);
    window.addEventListener("hashchange", reconcile);
    window.addEventListener("popstate", reconcile);
    window.addEventListener("resize", reconcile);
    document.body.addEventListener("htmx:afterSettle", reconcile);
    document.body.addEventListener("htmx:load", reconcile);
    setTimeout(reconcile, 250);
})();
