// mic.js  (shortened)
const micBtn   = document.getElementById("mic-btn");
const pulse    = document.getElementById("pulse-ring");
const hiddenIn = document.getElementById("hidden-rec");

/* iOS fallback */
if (typeof MediaRecorder === "undefined") {
  micBtn.onclick = () => hiddenIn.click();
  console.log("MediaRecorder unavailable – using native capture");
  return;
}

/* desktop / Android recorder */
let mediaRecorder, chunks = [];
async function startRec(){ /* …exact same code… */ }
function stopRec(){ /* … */ }
micBtn.onclick = () => document.body.classList.contains("recording") ? stopRec() : startRec();
