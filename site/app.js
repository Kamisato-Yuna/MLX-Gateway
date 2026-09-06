const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
if (!reducedMotion.matches && "IntersectionObserver" in window) {
    document.documentElement.classList.add("js-motion");
    const observer = new IntersectionObserver(
        (entries) => {
            entries.forEach((entry) => {
                if (entry.isIntersecting) {
                    entry.target.classList.add("visible");
                    observer.unobserve(entry.target);
                }
            });
        },
        { threshold: 0.08 },
    );
    document
        .querySelectorAll(".reveal")
        .forEach((element) => observer.observe(element));
}

const hero = document.querySelector(".hero");
const art = document.querySelector(".hero-art");
hero.addEventListener("pointermove", (event) => {
    if (reducedMotion.matches || event.pointerType !== "mouse") return;
    const bounds = hero.getBoundingClientRect();
    art.style.setProperty(
        "--tilt-y",
        `${((event.clientX - bounds.left) / bounds.width - 0.5) * 9}deg`,
    );
    art.style.setProperty(
        "--tilt-x",
        `${-((event.clientY - bounds.top) / bounds.height - 0.5) * 7}deg`,
    );
});
hero.addEventListener("pointerleave", () => {
    art.style.setProperty("--tilt-x", "0deg");
    art.style.setProperty("--tilt-y", "0deg");
});

const status = document.querySelector("#demo-status");
const output = document.querySelector("#demo-output");
const start = document.querySelector("#demo-start");
const description = document.querySelector("#step-description");
let demoTimer;
let running = false;
const descriptions = [
    "选择不会触发加载。API 请求也不会替你启动或切换模型。",
    "由你手动启停。同一时刻只运行一个模型，停止后释放其占用的内存。",
    "将模型 ID 与 API 地址填入客户端，以 Responses 文本接口发出请求。",
];
const connectionExample =
    'from openai import OpenAI\nclient = OpenAI(base_url="http://127.0.0.1:44110/v1", api_key="local")\nresponse = client.responses.create(\n    model="my-text-model", input="你好", store=False\n)\nprint(response.output_text)';

function selectStep(index) {
    document.querySelectorAll("[data-step]").forEach((button) => {
        const active = Number(button.dataset.step) === index;
        button.classList.toggle("active", active);
        button.setAttribute("aria-pressed", String(active));
    });
    description.textContent = descriptions[index];
}

function setStatus(text, state = "") {
    status.className = `model-status ${state}`;
    status.querySelector("span").textContent = text;
}

function resetDemo() {
    clearTimeout(demoTimer);
    running = false;
    start.disabled = false;
    start.textContent = "启动演示";
    setStatus("未启动");
    output.textContent = "等待你启动模型。";
}

function startDemo() {
    clearTimeout(demoTimer);
    selectStep(1);
    setStatus("模拟加载中…", "loading");
    start.disabled = true;
    start.textContent = "模拟加载中";
    output.textContent = "[演示] 读取所选模型配置\n[演示] 启动 MLX 后端…";
    demoTimer = setTimeout(
        () => {
            running = true;
            start.disabled = false;
            start.textContent = "停止演示";
            setStatus("服务就绪 · 演示", "ready");
            output.textContent =
                "[演示] 模型已就绪\n[演示] Responses 文本接口等待请求\n提示：此网页没有连接或启动你的本地服务。";
        },
        reducedMotion.matches ? 0 : 1000,
    );
}

start.addEventListener("click", () => {
    if (running) {
        resetDemo();
        selectStep(1);
        output.textContent =
            "[演示] 模型已停止，内存已释放。\n提示：以上为产品工作方式模拟。";
    } else startDemo();
});

document.querySelectorAll("[data-step]").forEach((button) => {
    button.addEventListener("click", () => {
        const index = Number(button.dataset.step);
        if (index === 0) {
            resetDemo();
            selectStep(0);
        } else if (index === 1) startDemo();
        else {
            clearTimeout(demoTimer);
            start.disabled = false;
            start.textContent = running ? "停止演示" : "启动演示";
            setStatus(
                running ? "服务就绪 · 演示" : "未启动",
                running ? "ready" : "",
            );
            selectStep(2);
            output.textContent = connectionExample;
        }
    });
});

let toastTimer;
function notify(message) {
    const toast = document.querySelector("#toast");
    clearTimeout(toastTimer);
    toast.textContent = message;
    toast.classList.add("visible");
    toastTimer = setTimeout(() => toast.classList.remove("visible"), 2800);
}

document.querySelectorAll("[data-copy]").forEach((button) => {
    button.addEventListener("click", async () => {
        try {
            await navigator.clipboard.writeText(button.dataset.copy);
            notify("已复制到剪贴板");
        } catch {
            notify("无法访问剪贴板，请选择旁边的文本手动复制");
        }
    });
});

// Source access remains usable without JavaScript or when GitHub is unavailable.
async function loadRelease() {
    const releaseStatus = document.querySelector("#release-status");
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 6000);
    try {
        const response = await fetch(
            "https://api.github.com/repos/Kamisato-Yuna/MLX-Gateway/releases/latest",
            {
                headers: { Accept: "application/vnd.github+json" },
                signal: controller.signal,
            },
        );
        if (response.status === 404) {
            releaseStatus.textContent =
                "尚无正式 Release · 你可以在 GitHub 关注发布进展。";
            return;
        }
        if (!response.ok) throw new Error("Release unavailable");
        const release = await response.json();
        const url = new URL(release.html_url);
        if (
            url.origin !== "https://github.com" ||
            !url.pathname.startsWith("/Kamisato-Yuna/MLX-Gateway/releases/")
        )
            throw new Error("Unexpected release URL");
        if (
            release.draft ||
            release.prerelease ||
            typeof release.tag_name !== "string"
        )
            throw new Error("Not a stable release");
        const link = document.createElement("a");
        link.href = url.href;
        link.target = "_blank";
        link.rel = "noopener noreferrer";
        link.textContent = `最新 Release：${release.tag_name} · 查看发布内容`;
        releaseStatus.replaceChildren(link);
        // A release alone does not establish a signed or notarized macOS installer.
        document.querySelector(".release-copy > p").textContent =
            "源码持续开放。GitHub 已有新发布，安装包及签名信息请查阅对应发布说明。";
    } catch {
        releaseStatus.textContent =
            "暂时无法同步版本，前往 GitHub Releases 查看最新进展。";
    } finally {
        clearTimeout(timeout);
    }
}
loadRelease();
