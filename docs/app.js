const scenes = {
  combined: {
    title: "Updated 12:34 PM",
    appName: "WindowWatch",
    items: [
      { kind: "claude", text: "26% 83%", detail: "Claude: 5h session 26%, 7d overall 83%" },
      { kind: "codex", text: "5% 2%", detail: "Codex: 5h session 5%, 7d overall 2%" },
    ],
  },
  backoff: {
    title: "Updated 12:34 PM",
    appName: "WindowWatch",
    items: [
      { kind: "claude", text: "26% 83%", detail: "Claude: 5h session 26%, 7d overall 83%" },
      { kind: "codex", text: "5% 2%", detail: "Codex: 5h session 5%, 7d overall 2%" },
    ],
  },
  claude: {
    title: "Updated 12:34 PM",
    appName: "ClaudeWindowWatch",
    items: [{ kind: "claude", text: "26% 83%", detail: "Claude: 5h session 26%, 7d overall 83%" }],
  },
  codex: {
    title: "Updated 12:34 PM",
    appName: "CodexWindowWatch",
    items: [{ kind: "codex", text: "5% 2%", detail: "Codex: 5h session 5%, 7d overall 2%" }],
  },
};

const statusCluster = document.getElementById("status-cluster");
const updatedRow = document.getElementById("updated-row");
const rowA = document.getElementById("row-a");
const rowB = document.getElementById("row-b");
const actionDanger = document.querySelector(".action.danger");

function capsule(kind, text) {
  const label = kind === "claude" ? "A" : "O";
  const name = kind === "claude" ? "capsule-claude" : "capsule-codex";
  return `
    <div class="capsule ${name}">
      <span class="logo-chip">${label}</span>
      <span>${text}</span>
    </div>
  `;
}

function render(sceneKey) {
  const scene = scenes[sceneKey];
  statusCluster.innerHTML = scene.items.map((item) => capsule(item.kind, item.text)).join("");
  updatedRow.textContent = sceneKey === "backoff" ? "Updated 12:34 PM • Claude backing off quietly" : scene.title;
  rowA.textContent = scene.items[0]?.detail ?? "";
  rowB.textContent = scene.items[1]?.detail ?? "";
  rowB.style.display = scene.items[1] ? "block" : "none";
  actionDanger.textContent = `Quit ${scene.appName}`;

  document.querySelectorAll("[data-scene]").forEach((button) => {
    button.classList.toggle("active", button.dataset.scene === sceneKey);
  });
}

document.querySelectorAll("[data-scene]").forEach((button) => {
  button.addEventListener("click", () => render(button.dataset.scene));
});

render("combined");
