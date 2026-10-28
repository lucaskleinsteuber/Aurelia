// Tiny in-memory DOM; it never opens or controls a browser.
export class TestNode extends EventTarget {
  constructor(tag = "", text = "") {
    super();
    this.tagName = tag.toUpperCase();
    this.children = [];
    this.parentNode = null;
    this.attributes = new Map();
    this.dataset = {};
    this.style = { setProperty() {} };
    this.value = "";
    this.disabled = this.checked = this.selected = this.hidden = false;
    this.text = text;
  }
  get firstChild() { return this.children[0] ?? null; }
  get isConnected() { return this === globalThis.document?.body || Boolean(this.parentNode?.isConnected); }
  get textContent() { return this.text + this.children.map((child) => child.textContent).join(""); }
  set textContent(value) { this.replaceChildren(); this.text = String(value); }
  setAttribute(key, value) {
    this.attributes.set(key, String(value));
    if (["disabled", "checked", "selected", "hidden"].includes(key)) this[key] = true;
    if (["value", "type", "class"].includes(key)) this[key === "class" ? "className" : key] = String(value);
  }
  getAttribute(key) { return this.attributes.get(key) ?? null; }
  append(...nodes) {
    for (let node of nodes) {
      if (!(node instanceof TestNode)) node = new TestNode("", String(node));
      node.remove();
      node.parentNode = this;
      this.children.push(node);
      if (this.tagName === "SELECT" && (node.selected || this.children.length === 1)) this.value = node.value;
    }
  }
  replaceChildren(...nodes) {
    for (const child of [...this.children]) child.remove();
    this.text = "";
    this.append(...nodes);
  }
  remove() {
    if (this.parentNode) this.parentNode.children.splice(this.parentNode.children.indexOf(this), 1);
    this.parentNode = null;
  }
  replaceWith(node) {
    const parent = this.parentNode;
    if (!parent) return;
    const index = parent.children.indexOf(this);
    this.remove();
    node.parentNode = parent;
    parent.children.splice(index, 0, node);
  }
  querySelectorAll(selector) {
    const selectors = selector.split(",").map((item) => item.trim());
    const matches = (node) => selectors.some((item) => {
      const match = /^(\w+)(?:\[([^=]+)=["']?([^"'\]]+)["']?\])?$/.exec(item);
      return match && node.tagName === match[1].toUpperCase() && (!match[2] || node.getAttribute(match[2]) === match[3]);
    });
    return this.children.flatMap((child) => [...(matches(child) ? [child] : []), ...child.querySelectorAll(selector)]);
  }
  querySelector(selector) { return this.querySelectorAll(selector)[0] ?? null; }
  focus() {}
  showModal() { this.open = true; }
  close() { this.open = false; this.dispatchEvent(new Event("close")); }
  click() { if (!this.disabled) this.dispatchEvent(new Event("click", { bubbles: true, cancelable: true })); }
  dispatchEvent(event) {
    const result = super.dispatchEvent(event);
    if (event.bubbles && this.parentNode) this.parentNode.dispatchEvent(event);
    return result;
  }
}

export const flush = async () => { for (let index = 0; index < 8; index++) await new Promise(setImmediate); };
export const deferred = () => { let resolve, reject; const promise = new Promise((done, fail) => { resolve = done; reject = fail; }); return { promise, resolve, reject }; };
export function installDOM(t) {
  const prior = { document: globalThis.document, Node: globalThis.Node };
  globalThis.Node = TestNode;
  globalThis.document = { body: new TestNode("body"), createElement: (tag) => new TestNode(tag), createElementNS: (_namespace, tag) => new TestNode(tag), createTextNode: (text) => new TestNode("", text) };
  t.after(() => { globalThis.document = prior.document; globalThis.Node = prior.Node; });
}
export const all = (element) => [element, ...element.children.flatMap(all)];
export function button(element, text) { const result = all(element).find((node) => node.tagName === "BUTTON" && node.textContent === text); if (!result) throw new Error(`Missing button ${text}`); return result; }
export function input(element, label) { const result = all(element).find((node) => node.tagName === "INPUT" && node.getAttribute("aria-label") === label); if (!result) throw new Error(`Missing input ${label}`); return result; }
