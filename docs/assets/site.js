const yearNodes = document.querySelectorAll("[data-current-year]");
const currentYear = new Date().getFullYear().toString();

for (const node of yearNodes) {
  node.textContent = currentYear;
}

const currentPath = window.location.pathname.split("/").pop() || "index.html";

for (const link of document.querySelectorAll(".site-nav a")) {
  const href = link.getAttribute("href");
  if (href === currentPath || (currentPath === "" && href === "index.html")) {
    link.setAttribute("aria-current", "page");
  }
}
