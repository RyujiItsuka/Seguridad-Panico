// Edge Function: whatsapp
// Envío de mensajes y archivos vía Green API con el token SIEMPRE en el
// servidor (nunca se expone en el cliente / APK).
//
// Motivo de seguridad: el token de Green API permite enviar WhatsApp desde la
// cuenta del proyecto. Si viviera en el APK, cualquiera que descompile la app
// podría extraerlo y usarlo. Aquí solo el cliente conoce la URL de esta función.
//
// Despliegue:
//   supabase secrets set GREEN_API_INSTANCE_ID=waInstanceXXXXXXXX
//   supabase secrets set GREEN_API_TOKEN=tu_token_de_green_api
//   supabase secrets set GREEN_API_BASE_URL=https://7105.api.greenapi.com   # opcional
//   supabase functions deploy whatsapp
//
// Uso (dos formatos soportados):
//   1) Mensaje (JSON):
//      POST /functions/v1/whatsapp
//      Headers: apikey: <anon key>, Authorization: Bearer <anon key | user JWT>
//      Body:   { "action": "sendMessage", "chatId": "51976264949@c.us", "message": "..." }
//
//   2) Archivo (multipart/form-data):
//      POST /functions/v1/whatsapp
//      Fields: action=sendFileByUpload, chatId, caption, fileName, file=<binario>

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const GREEN_API_BASE_URL = Deno.env.get("GREEN_API_BASE_URL") ??
  "https://7105.api.greenapi.com";
const GREEN_API_INSTANCE_ID = Deno.env.get("GREEN_API_INSTANCE_ID") ?? "";
const GREEN_API_TOKEN = Deno.env.get("GREEN_API_TOKEN") ?? "";

// Tiempos de espera del proveedor (ms). Se mantienen cortos para que la ruta
// crítica de pánico no se tarde; el reintento ocurre en este servidor.
const GREEN_TIMEOUT_MS = 8000;
const GREEN_RETRIES = 2;

const RATE_LIMIT = 30; // envíos por minuto por IP
const rateLimitMap = new Map<string, { count: number; resetAt: number }>();

function json(
  body: unknown,
  status = 200,
  extraHeaders: Record<string, string> = {},
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...CORS_HEADERS,
      "Content-Type": "application/json",
      ...extraHeaders,
    },
  });
}

function isRateLimited(ip: string): boolean {
  const now = Date.now();
  const entry = rateLimitMap.get(ip);
  if (!entry || now > entry.resetAt) {
    rateLimitMap.set(ip, { count: 1, resetAt: now + 60_000 });
    return false;
  }
  entry.count += 1;
  return entry.count > RATE_LIMIT;
}

function greenApiUrl(action: string): string {
  return `${GREEN_API_BASE_URL}/${GREEN_API_INSTANCE_ID}/${action}/${GREEN_API_TOKEN}`;
}

// Llama a Green API con timeout y un reintento ante fallo de red o 5xx.
// Los 4xx NO se reintenta (error del cliente, p.ej. chatId mal formado).
async function callGreen(
  url: string,
  init: RequestInit,
): Promise<Response> {
  let lastResponse: Response | null = null;
  let lastError: unknown = null;

  for (let attempt = 0; attempt < GREEN_RETRIES; attempt++) {
    try {
      const res = await fetch(url, {
        ...init,
        signal: AbortSignal.timeout(GREEN_TIMEOUT_MS),
      });
      if (res.ok) return res;
      if (res.status >= 500) {
        lastResponse = res;
        continue; // reintenta en error del servidor del proveedor
      }
      return res; // 4xx: no reintentar
    } catch (err) {
      lastError = err; // timeout / red caída -> reintenta
    }
  }

  if (lastResponse) return lastResponse;
  throw lastError ?? new Error("Green API no disponible");
}

serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return json({ error: "Método no permitido. Use POST." }, 405);
  }

  // Las apps mógeles no envían Origin; solo se bloquea un origen web explícito.
  const origin = req.headers.get("Origin");
  if (origin && !origin.includes("localhost") && !origin.includes("capacitor")) {
    return json({ error: "Origen no permitido" }, 403);
  }

  const ip =
    req.headers.get("x-forwarded-for")?.split(",")[0].trim() ?? "unknown";
  if (isRateLimited(ip)) {
    return json({ error: "Demasiados envíos. Espere un minuto." }, 429);
  }

  if (!GREEN_API_INSTANCE_ID || !GREEN_API_TOKEN) {
    console.error("[whatsapp] Faltan GREEN_API_INSTANCE_ID / GREEN_API_TOKEN");
    return json({ error: "Servicio de WhatsApp no configurado." }, 500);
  }

  try {
    const contentType = req.headers.get("content-type") ?? "";

    // ---- 2) Archivo (fotos de evidencia) vía multipart/form-data ----
    if (contentType.includes("multipart/form-data")) {
      const form = await req.formData();
      const chatId = String(form.get("chatId") ?? "");
      const caption = form.get("caption");
      const fileName = form.get("fileName");
      const file = form.get("file");

      if (!/^\d{5,20}@c\.us$/.test(chatId)) {
        return json({ error: "chatId inválido" }, 400);
      }
      if (!(file instanceof File)) {
        return json({ error: "Falta el archivo (campo 'file')" }, 400);
      }

      const outbound = new FormData();
      outbound.append("chatId", chatId);
      if (typeof caption === "string") outbound.append("caption", caption);
      if (typeof fileName === "string") outbound.append("fileName", fileName);
      outbound.append(
        "file",
        file,
        typeof fileName === "string" && fileName.length > 0
          ? fileName
          : file.name,
      );

      const res = await callGreen(greenApiUrl("sendFileByUpload"), {
        method: "POST",
        body: outbound,
      });
      const text = await res.text();
      console.log(
        `[whatsapp][sendFileByUpload] status=${res.status} body=${text}`,
      );
      return new Response(text, {
        status: res.status,
        headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
      });
    }

    // ---- 1) Mensaje de texto vía JSON ----
    let payload: Record<string, unknown>;
    try {
      payload = await req.json();
    } catch {
      return json({ error: "Body JSON inválido" }, 400);
    }

    const action = String(payload.action ?? "sendMessage");
    const chatId = String(payload.chatId ?? "");
    const message = String(payload.message ?? "");

    if (action !== "sendMessage") {
      return json({ error: `Acción no soportada: ${action}` }, 400);
    }
    if (!/^\d{5,20}@c\.us$/.test(chatId)) {
      return json({ error: "chatId inválido" }, 400);
    }
    if (message.trim().length === 0) {
      return json({ error: "El mensaje no puede estar vacío" }, 400);
    }

    const res = await callGreen(greenApiUrl("sendMessage"), {
      method: "POST",
      headers: { "Content-Type": "application/json; charset=utf-8" },
      body: JSON.stringify({ chatId, message }),
    });
    const text = await res.text();
    console.log(`[whatsapp][sendMessage] status=${res.status} body=${text}`);
    return new Response(text, {
      status: res.status,
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  } catch (err) {
    console.error(`[whatsapp] ERROR: ${err}`);
    return json({ error: "No se pudo enviar por WhatsApp." }, 502);
  }
});
