(function () {
  const pingButton = document.getElementById("pingButton");
  const pingResult = document.getElementById("pingResult");

  if (!pingButton || !pingResult) {
    return;
  }

  pingButton.addEventListener("click", function () {
    const now = new Date();
    pingResult.textContent = "App is ready: " + now.toLocaleString("ja-JP");
  });
})();
