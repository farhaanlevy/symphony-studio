(() => {
  "use strict";

  const CopyText = {
    mounted() {
      this.handleClick = async () => {
        const value = this.el.dataset.copyValue || "";
        const label = this.el.dataset.copyLabel || "Value";
        const stableLabel = this.el.textContent;

        if (!value || !navigator.clipboard) return;

        try {
          await navigator.clipboard.writeText(value);
          this.el.textContent = "Copied";
          this.el.dataset.copyState = "complete";
          this.pushEvent("copy_complete", {label});
          window.clearTimeout(this.copyTimer);
          this.copyTimer = window.setTimeout(() => {
            this.el.textContent = stableLabel;
            delete this.el.dataset.copyState;
          }, 1600);
        } catch (_error) {
          this.el.textContent = "Copy failed";
          this.el.dataset.copyState = "failed";
        }
      };

      this.el.addEventListener("click", this.handleClick);
    },

    destroyed() {
      window.clearTimeout(this.copyTimer);
      this.el.removeEventListener("click", this.handleClick);
    }
  };

  window.SymphonyStudioHooks = {CopyText};
})();
