/// <reference types="vite/client" />

declare const __COMMIT_HASH__: string;
declare const __COMMIT_DATE__: string;
declare const __CAPACITOR_VERSION__: string;
/** 是否为 iOS (Capacitor) 构建，用于条件编译剔除其它端不需要的代码 */
declare const __IS_IOS_BUILD__: boolean;

declare module "*.vue" {
  import type { DefineComponent } from "vue";
  const component: DefineComponent<object, object, any>;
  export default component;
}
