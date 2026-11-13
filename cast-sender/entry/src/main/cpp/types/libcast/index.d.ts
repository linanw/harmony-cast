export const start: (host: string, code: string, width: number, height: number, port?: number) => Promise<void>;
export const stop: () => void;
export const status: () => string;
export interface AudioRequest { serial: number; enabled: boolean; live: boolean; }
export const audioRequest: () => AudioRequest;
export const audioReply: (serial: number, enabled: boolean, success: boolean) => void;
