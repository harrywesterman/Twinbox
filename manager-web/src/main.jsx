import React from "react";
import ReactDOM from "react-dom/client";
import App from "./App";
import "./index.css";

const rootElement = document.getElementById("root");

function markAppReady() {
  document.documentElement.classList.add("app-ready");
}

function waitForAppContent() {
  if (!rootElement) {
    return;
  }

  if (rootElement.children.length > 0) {
    markAppReady();
    return;
  }

  const observer = new MutationObserver(() => {
    if (rootElement.children.length > 0) {
      observer.disconnect();
      markAppReady();
    }
  });

  observer.observe(rootElement, { childList: true, subtree: true });

  window.requestAnimationFrame(() => {
    if (rootElement.children.length > 0) {
      observer.disconnect();
      markAppReady();
    }
  });
}

ReactDOM.createRoot(rootElement).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
);

waitForAppContent();
