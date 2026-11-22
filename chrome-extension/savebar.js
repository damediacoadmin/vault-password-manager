// "Save this login?" bar shown after you sign in or sign up somewhere new.
// The password itself never comes to this page; Vault already holds it for this tab.
(async () => {
  const d = await send({ type: "offer-data" });
  if (!d.ok) return send({ type: "offer-answer", answer: "later" });
  const upd = d.status === "update";
  $("#eyebrow").textContent = upd ? "Vault · Update password" : "Vault · Save login";
  $("#title").textContent = upd ? `Update your ${d.title} password?` : `Save your ${d.title} login?`;
  $("#save").textContent = upd ? "Update" : "Save";
  if (upd) {
    $("#fields").hidden = true;
    const u = $("#updUser"); u.hidden = false; u.textContent = `${d.username || "No username"} · ${d.host}`;
    document.body.style.height = "auto";
  } else {
    $("#name").value = d.title;
    $("#user").value = d.username;
    $("#users").replaceChildren(...(d.usernames || []).map((u) => h("option", { value: u })));
  }
  $("#save").onclick = async () => {
    $("#save").disabled = true;
    const r = await send({ type: "offer-answer", answer: "save", title: $("#name").value.trim(), username: upd ? undefined : $("#user").value.trim() });
    if (r && !r.ok) { $("#save").disabled = false; $("#title").textContent = r.error || "Could not save. Is Vault unlocked?"; }
  };
  $("#later").onclick = () => send({ type: "offer-answer", answer: "later" });
  $("#never").onclick = () => send({ type: "offer-answer", answer: "never" });
  addEventListener("keydown", (e) => { if (e.key === "Escape") send({ type: "offer-answer", answer: "later" }); });
})();
