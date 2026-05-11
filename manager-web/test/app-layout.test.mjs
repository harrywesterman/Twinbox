import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const appSourcePath = new URL("../src/App.jsx", import.meta.url);
const questionFlowPath = new URL("../src/question-flow.js", import.meta.url);
const helperSourcePath = new URL("../src/step-presentation.js", import.meta.url);
const appStylesPath = new URL("../src/App.css", import.meta.url);
const viteConfigPath = new URL("../vite.config.js", import.meta.url);
const indexHtmlPath = new URL("../index.html", import.meta.url);

test("app source defines a minimal wizard shell with guided input and step-by-step install controls", async () => {
  const source = await readFile(appSourcePath, "utf8");
  const questionFlow = await readFile(questionFlowPath, "utf8");

  assert.match(source, /className="wizard-shell"/, "expected the wizard shell");
  assert.match(source, /wizard-layout-minimal/, "expected a minimal wizard layout");
  assert.match(source, /wizard-flow-minimal/, "expected the stacked setup flow");
  assert.match(source, /className="wizard-start-screen"/, "expected a start screen");
  assert.match(source, /wizard-guide-panel/, "expected an educational guide panel");
  assert.match(source, /wizard-choice-grid/, "expected route choices to render as cards");
  assert.match(source, /Previous/, "expected back navigation");
  assert.match(source, /{primaryActionLabel}/, "expected the forward action label");
  assert.match(
    source,
    /Continue to installation/,
    "expected the last question to lead into the install phase"
  );
  assert.match(source, /Install all/, "expected an install-all action in the install phase");
  assert.match(source, /type="range"/, "expected the scale slider");
  assert.match(source, /wizard-step-actions-panel/, "expected a dedicated step 1 helper bar");
  assert.match(source, /Help me with free IPs/, "expected the IP helper button");
  assert.match(source, /Assigning free IPs…/, "expected the helper button to show a loading label");
  assert.match(
    source,
    /Checking the local subnet for free IP addresses\. Please wait while Twinbox fills them in automatically\./,
    "expected inline wait feedback for the IP helper"
  );
  assert.match(source, /is-pending/, "expected a pending network status style hook");
  assert.match(
    source,
    /Cluster identity/,
    "expected the Talos cluster name to be shown as a derived summary"
  );
  assert.match(
    source,
    /Twinbox saves this name automatically from the wizard choice/,
    "expected the cluster name to be auto-saved from the earlier choice"
  );
  assert.doesNotMatch(
    questionFlow,
    /Cluster name/,
    "expected the Talos questions to stop asking for the cluster name"
  );
  assert.match(
    source,
    /showImportButton =\s*!isInstallPhase && !model\.completion && currentStep\?\.id !== "provision-nodes"/,
    "expected the topbar import button to hide on step 1"
  );
  assert.match(source, /1\. VM sizing/, "expected sizing to come first");
  assert.match(source, /VM landing/, "expected the VM placement block to be explicit");
  assert.match(source, /wizard-placement-board/, "expected the host placement board");
  assert.match(source, /Automatic placement/, "expected automatic placement controls");
  assert.match(
    source,
    /onReset=\{applyProvisionPlacementHelp\}/,
    "expected the placement reset button to reuse the placement helper"
  );
  assert.match(source, /hasPlacementAssignments/, "expected the step 1 auto-placement guard");
  assert.match(
    source,
    /buildPlacementSuggestionKey/,
    "expected a stable suggestion key for automatic placement"
  );
  assert.match(
    source,
    /placementSuggestionKeyRef\.current = placementSuggestionKey/,
    "expected the auto-placement effect to remember the last suggestion"
  );
  assert.match(
    source,
    /void applyProvisionPlacementHelp\(\);/,
    "expected automatic placement to run when step 1 opens without placements"
  );
  assert.match(
    source,
    /buildAutomaticProvisionPlacementResult/,
    "expected automatic placement to use one shared helper path"
  );
  assert.match(source, /setPlacementStatus\(/, "expected inline placement feedback state");
  assert.match(
    source,
    /wizard-network-check-summary is-\$\{placementStatus\.tone \|\| "neutral"\}/,
    "expected inline placement status styling"
  );
  assert.doesNotMatch(
    source,
    /Keep VM scale separate from networking/,
    "expected the old network summary heading to be removed"
  );
  assert.match(source, /Per-VM IPs/, "expected a per-VM IP list");
  assert.match(source, /wizard-network-vm-list/, "expected the VM IP list container");
  assert.match(source, /wizard-status-badge/, "expected status badges for each VM");
  assert.match(source, /wizard-field-dns/, "expected a compact DNS field variant");
  assert.doesNotMatch(
    source,
    /one-time free address suggestion/,
    "expected the one-time IP allocation note to be removed"
  );
  assert.doesNotMatch(
    source,
    /Start IP/,
    "expected the fixed start IP field to be removed from the wizard"
  );
  assert.doesNotMatch(
    source,
    /className="technical-panel"/,
    "expected technical details to be removed"
  );
  assert.match(source, /Output/, "expected a visible output panel");
  assert.match(source, /wizard-step-icon/, "expected step icons in the header");
  assert.match(
    source,
    /wizard-step-icon-large/,
    "expected a larger icon in the active step header"
  );
  assert.match(
    source,
    /wizard-step-icon-artwork/,
    "expected the active step icon to render image artwork"
  );
  assert.match(
    source,
    /iconArtworkUrl/,
    "expected the active step artwork URL to be wired through"
  );
  assert.match(source, /wizard-step-pitch/, "expected a positive step description");
  assert.match(source, /Deploy Talos Cluster/, "expected the Talos bootstrap step label");
  assert.match(source, /Load saved answers/, "expected saved answers to live in the top bar");
  assert.match(
    source,
    /readStoredWizardState/,
    "expected startup state to use the clean default wizard state"
  );
  assert.match(
    source,
    /setWizardPhase\("questions"\)/,
    "expected a recreated cluster to restart in the question flow"
  );
  assert.match(
    source,
    /getQuestionSteps\(answersRef\.current\)\[0\]\?\.id \|\| "provision-nodes"/,
    "expected a recreated cluster to restart at the first question"
  );
  assert.match(
    source,
    /clearInstallStepLogs\(\)/,
    "expected recreation to clear stale install logs"
  );
  assert.match(
    source,
    /Loading cluster data…/,
    "expected a visible loading banner while refreshing"
  );
  assert.match(
    source,
    /wizard-vm-card is-fixed/,
    "expected the management VM to render as a fixed VM card"
  );
  assert.match(
    source,
    /Fixed on this host and included in the resource budget\./,
    "expected the fixed management VM copy"
  );
  assert.doesNotMatch(
    source,
    /wizard-placement-management-card/,
    "expected the old standalone management card to be removed"
  );
  assert.doesNotMatch(
    source,
    /wizard-placement-fixed-details/,
    "expected the old fixed-details block to be removed"
  );
  assert.doesNotMatch(
    source,
    /Sizing comes first/,
    "expected the old explanatory placement note to be removed"
  );
  assert.doesNotMatch(
    source,
    /Retry balanced suggestion/,
    "expected the old placement button label to be removed"
  );
  assert.doesNotMatch(
    source,
    /resetPlacementToSuggested/,
    "expected the old no-op placement reset handler to be removed"
  );
  assert.doesNotMatch(
    source,
    /Waiting for step 1 suggestions to load/,
    "expected the old loading copy to be removed"
  );
  assert.doesNotMatch(
    source,
    /Twinbox repeats the same check automatically when you click Next\./,
    "expected the old IP check helper copy to be removed"
  );
  assert.doesNotMatch(
    source,
    /Green means the suggested address was checked once\./,
    "expected the old VM status legend copy to be removed"
  );
  assert.doesNotMatch(
    source,
    /One address per VM, no fixed block/,
    "expected the old per-VM heading copy to be removed"
  );
  assert.doesNotMatch(
    source,
    /Base zone for platform hostnames/,
    "expected the old DNS helper copy to be removed"
  );
  assert.doesNotMatch(
    source,
    /No preset default/,
    "expected the DNS field to hide the default copy"
  );
  assert.match(source, /wizard-install-stage/, "expected a centered install stage");
  assert.match(
    source,
    /wizard-install-stage-icon/,
    "expected the install header to reserve space for a large icon"
  );
  assert.match(
    source,
    /wizard-install-output/,
    "expected a dedicated output window for install mode"
  );
  assert.match(
    source,
    /wizard-install-actions-row/,
    "expected the install controls below the output window"
  );
  assert.doesNotMatch(
    source,
    /\|\| isCurrentStepComplete/,
    "expected the install action to stay available even after a step is complete"
  );
  assert.match(
    source,
    /href=\{adminDashboardUrl\}/,
    "expected the admin dashboard action to use a direct link"
  );
  assert.match(
    source,
    /target="_blank"/,
    "expected the admin dashboard action to open in a new tab"
  );
  const adminDashboardTextIndex = source.indexOf("Open Admin Dashboard");
  assert.ok(
    adminDashboardTextIndex >= 0,
    "expected the admin dashboard action to exist in the source"
  );
  const adminDashboardBlock = source.slice(
    Math.max(0, adminDashboardTextIndex - 220),
    adminDashboardTextIndex + 40
  );
  assert.match(
    adminDashboardBlock,
    /className="button button-primary"/,
    "expected the admin dashboard action to use the primary blue style"
  );
  assert.doesNotMatch(
    source,
    /window\.open\(adminDashboardUrl/,
    "expected the admin dashboard action to avoid popup-based navigation"
  );
  assert.match(source, /installLogsByStepRef/, "expected the install view to cache logs per step");
  assert.match(source, /setInstallStepLogs\(/, "expected the install pane to write per-step logs");
  assert.match(
    source,
    /renderStepIcon\(\s*activeStepPresentation,\s*"wizard-step-icon wizard-step-icon-large wizard-install-stage-icon"\s*\)/,
    "expected the install stage to render the large icon artwork above the title"
  );
  assert.match(
    source,
    /model\.activity\.rawLogOutput \|\| ""/,
    "expected the install pane to render only the current step output"
  );
  assert.doesNotMatch(
    source,
    /visibleInstallLogOutput/,
    "expected the old log fallback to be removed"
  );
  assert.doesNotMatch(
    source,
    /No worker output yet/,
    "expected the placeholder log copy to be removed"
  );
  assert.doesNotMatch(source, /CURRENT STEP/, "expected the install phase to hide step context");
  assert.doesNotMatch(
    source,
    /wizard-step-context/,
    "expected the install phase to stay blank apart from output"
  );
  assert.match(source, /wizard-log-viewport/, "expected the live output to be scrollable");
  assert.doesNotMatch(source, /Explore Twinbox/, "should no longer read like a landing page");

  assert.match(
    questionFlow,
    /Enter the DNS domain for your cluster\./,
    "expected the DNS helper sentence in the question flow"
  );
  assert.doesNotMatch(
    questionFlow,
    /Base zone for platform hostnames/,
    "expected the old DNS helper copy to be removed from the question flow"
  );
  assert.match(
    questionFlow,
    /default:\s*90/,
    "expected the step 1 scale default to start at 90 percent"
  );
  assert.match(
    questionFlow,
    /controlplane_count[\s\S]*default:\s*3/,
    "expected the step 1 control-plane default to be 3"
  );
  assert.match(
    questionFlow,
    /worker_count[\s\S]*default:\s*3/,
    "expected the step 1 worker default to be 3"
  );
});

test("web helper maps real icon artwork from local assets", async () => {
  const source = await readFile(helperSourcePath, "utf8");

  assert.match(
    source,
    /STEP_ICON_ASSETS/,
    "expected a step-to-asset map for the downloaded app icons"
  );
  assert.match(
    source,
    /new URL\(`\.\/assets\/step-icons\//,
    "expected SVG artwork to be referenced through import.meta.url"
  );
  assert.match(source, /assets\/step-icons/, "expected the icons to live inside the web repo");
  assert.match(source, /icon_artwork_url/, "expected the helper to expose artwork URLs to the UI");
});

test("styles define a wizard-first, responsive installer layout", async () => {
  const css = await readFile(appStylesPath, "utf8");

  assert.match(css, /\.wizard-shell\s*\{/, "expected wizard shell styling");
  assert.match(css, /\.wizard-layout\s*\{/, "expected wizard layout grid");
  assert.match(css, /\.wizard-layout-minimal\s*\{/, "expected the minimal wizard layout override");
  assert.match(css, /\.wizard-workspace-minimal\s*\{/, "expected the simplified workspace");
  assert.match(css, /\.wizard-workspace-install\s*\{/, "expected the centered install workspace");
  assert.match(
    css,
    /\.wizard-flow-minimal\s*\{/,
    "expected the stacked active-step/output surface"
  );
  assert.match(css, /\.wizard-start-screen\s*\{/, "expected the start screen layout");
  assert.match(css, /\.wizard-guide-panel\s*\{/, "expected the educational guide surface");
  assert.match(css, /\.wizard-choice-grid\s*\{/, "expected numbered choice cards");
  assert.match(css, /\.wizard-step-actions-panel\s*\{/, "expected the step 1 helper panel");
  assert.match(css, /\.wizard-step-actions-panel-actions\s*\{/, "expected the helper button grid");
  assert.match(
    css,
    /\.wizard-network-check-summary\.is-pending\s*\{/,
    "expected a pending loading style for IP suggestions"
  );
  assert.match(
    css,
    /\.wizard-network-check-summary\.is-warning\s*\{/,
    "expected warning styling for partial placement"
  );
  assert.match(css, /\.wizard-log-viewport\s*\{/, "expected a scrolling live-log viewport");
  assert.match(css, /\.wizard-output-panel\.is-live\s*\{/, "expected live output emphasis");
  assert.doesNotMatch(
    css,
    /\.technical-panel\[open\]\s*\{/,
    "expected technical details to be removed"
  );
  assert.match(
    css,
    /\.wizard-output-panel-minimal\s*\{/,
    "expected output to stay visible on the page"
  );
  assert.match(css, /\.wizard-vm-card\.is-fixed\s*\{/, "expected a fixed VM card style");
  assert.match(css, /\.wizard-install-stage\s*\{/, "expected a dedicated install stage wrapper");
  assert.match(
    css,
    /\.wizard-install-stage-icon\s*\{/,
    "expected the install-stage icon treatment"
  );
  assert.match(
    css,
    /\.wizard-install-output\s*\{/,
    "expected a large output window for install mode"
  );
  assert.match(
    css,
    /\.wizard-install-output[\s\S]*height:\s*clamp\(300px,\s*46dvh,\s*600px\);/,
    "expected the install output to scale with the viewport"
  );
  assert.match(
    css,
    /\.wizard-install-actions-row\s*\{/,
    "expected the install buttons to sit under the output window"
  );
  assert.match(
    css,
    /\.wizard-log-output\s*\{[\s\S]*min-height:\s*360px;/,
    "expected the default script output panel"
  );
  assert.match(css, /\.wizard-step-icon-large\s*\{/, "expected the active-step icon treatment");
  assert.match(
    css,
    /\.wizard-field input\[type="range"\]\s*\{/,
    "expected the range slider styling"
  );
  assert.match(css, /\.wizard-field-dns\s*\{/, "expected a compact DNS field style");
  assert.doesNotMatch(css, /\.wizard-risk-list\s*\{/, "expected current risks to be removed");
  assert.match(css, /@media \(max-width:\s*1200px\)/, "expected large-tablet responsiveness");
  assert.match(css, /@media \(max-width:\s*720px\)/, "expected mobile responsiveness");
});

test("vite and document metadata still support relative hosting", async () => {
  const viteConfig = await readFile(viteConfigPath, "utf8");
  const indexHtml = await readFile(indexHtmlPath, "utf8");

  assert.match(viteConfig, /base:\s*"\.\/"/, "expected relative asset paths");
  assert.match(indexHtml, /lang="en"/, "expected English language metadata");
  assert.match(indexHtml, /Twinbox Web Installation Wizard/, "expected the wizard title");
  assert.match(
    indexHtml,
    /Loading Twinbox cluster setup/,
    "expected a boot splash while React starts"
  );
});
