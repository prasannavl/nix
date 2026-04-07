function typeWrite() {
	function clearElementsAndStoreText(ids) {
		const texts = {};
		ids.forEach((id) => {
			const element = document.getElementById(id);
			texts[id] = element.innerHTML;
			element.innerHTML = "&nbsp;";
		});
		return texts;
	}

	const els = ["s1", "s2", "f1", "f2"];
	const texts = clearElementsAndStoreText(els);

	function startTheater() {
		const theater = theaterJS({
			autoplay: true,
			minSpeed: 100,
			maxSpeed: 450,
		});
		theater
			.on("type:start", () => {
				const a = theater.getCurrentActor();
				a.$element.classList.add("actor--typing");
				// N-1 scene start
				if (a.name === "f1") {
					const logo = document.querySelector(".logo");
					logo.style.animation = "scale-pulse 1.4s ease infinite";
				} else if (a.name === "f2") {
				}
			})
			.on("type:end", () => {
				const a = theater.getCurrentActor();
				if (a.name !== "f2") {
					a.$element.classList.remove("actor--typing");
				} else if (a.name === "f2") {
					// Last scene end
					const logo = document.querySelector(".logo");
					// Store original dimensions
					const width = logo.offsetWidth;
					const height = logo.offsetHeight;
					logo.style.minWidth = `${width}px`;
					logo.style.minHeight = `${height}px`;
					// Flip transition to new logo
					logo.style.animation = "flip-out 0.3s ease forwards";

					// Wait for flip-out animation to complete before switching
					logo.addEventListener("animationend", function onFlipOut(e) {
						if (e.animationName === "flip-out") {
							logo.removeEventListener("animationend", onFlipOut);
							logo.src = "/icons/logo/llmug-wide-rect.svg";
							logo.style.animation = "flip-in 0.6s ease forwards";
						}
					});
				}
			});

		theater
			.addActor("s1", { speed: 1.2, accuracy: 1 })
			.addActor("s2", { speed: 1.2, accuracy: 0.9 })
			.addActor("f1", { speed: 1.3, accuracy: 1 })
			.addActor("f2", { speed: 0.8, accuracy: 0.2 })
			.addScene(`s1:${texts.s1}`)
			.addScene(`s2:${texts.s2}`)
			.addScene(`f1:${texts.f1}`)
			.addScene(`f2:${texts.f2}`);
	}

	setTimeout(() => {
		startTheater();
	}, 1500);
}

window.addEventListener("load", () => {
	typeWrite();
	document.getElementById("center-block").classList.remove("js-wait");
});
