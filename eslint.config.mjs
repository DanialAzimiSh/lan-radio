// npm run lint - the listener page's scripts, with the gsap-motion audit on the GSAP animations
// (tweens made per tap, missing reduced-motion branches, animations nothing ever tears down, ...).
import js from "@eslint/js";
import globals from "globals";
import gsapMotion from "@mehshekari/eslint-plugin-gsap-motion";

export default [
  { ignores: ["listen/vendor/**", "node_modules/**"] },
  {
    files: ["listen/**/*.js"],
    languageOptions: {
      ecmaVersion: 2024,
      sourceType: "script",
      globals: { ...globals.browser, gsap: "readonly", Physics2DPlugin: "readonly", Draggable: "readonly", InertiaPlugin: "readonly", SplitText: "readonly", CustomEase: "readonly", ScrambleTextPlugin: "readonly", RadioLikes: "readonly", RadioFeedback: "readonly", RadioRequests: "readonly", createLivePlayer: "readonly" },
    },
    rules: js.configs.recommended.rules,
  },
  { files: ["listen/**/*.js"], ...gsapMotion.configs.recommended },
  {
    // the admin panel's scripts: Alpine components, no animations
    files: ["panel/js/**/*.js"],
    languageOptions: {
      ecmaVersion: 2024,
      sourceType: "script",
      globals: { ...globals.browser, Alpine: "readonly" },
    },
    rules: js.configs.recommended.rules,
  },
];
