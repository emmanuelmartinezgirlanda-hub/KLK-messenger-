package api

import (
	"errors"
	"html/template"
	"log/slog"
	"net/http"

	"github.com/klk-app/klk-server/internal/store"
)

// Legal: datos de contacto para la política de privacidad y la página de soporte
// (Apple y Google las piden para publicar la app).
type Legal struct {
	Owner        string // responsable, p. ej. "Emmanuel Martínez"
	SupportEmail string // correo de soporte
	Updated      string // fecha de la última versión de la política
}

// deleteAccount borra la cuenta del servidor (Apple exige poder hacerlo desde la app).
func (s *Server) deleteAccount(w http.ResponseWriter, r *http.Request) {
	dev := deviceFrom(r)
	if err := s.store.DeleteAccount(r.Context(), dev.AccountID); err != nil && !errors.Is(err, store.ErrNotFound) {
		slog.Error("borrar cuenta", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal", "no se pudo borrar la cuenta, prueba otra vez")
		return
	}
	if s.hub != nil {
		s.hub.Kick(dev.AccountID)
	}
	s.touched.Delete(dev.AccountID)
	slog.Info("cuenta borrada por su dueño")
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) legalData() Legal {
	l := s.Legal
	if l.Owner == "" {
		l.Owner = "KLK messenger"
	}
	if l.Updated == "" {
		l.Updated = "26 de octubre de 2026"
	}
	return l
}

func (s *Server) privacyPage(w http.ResponseWriter, _ *http.Request) { s.renderLegal(w, privacyTmpl) }
func (s *Server) supportPage(w http.ResponseWriter, _ *http.Request) { s.renderLegal(w, supportTmpl) }
func (s *Server) termsPage(w http.ResponseWriter, _ *http.Request)   { s.renderLegal(w, termsTmpl) }
func (s *Server) deletePage(w http.ResponseWriter, _ *http.Request)  { s.renderLegal(w, deleteTmpl) }

func (s *Server) renderLegal(w http.ResponseWriter, t *template.Template) {
	h := w.Header()
	h.Set("Content-Type", "text/html; charset=utf-8")
	h.Set("Cache-Control", "public, max-age=600")
	h.Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; img-src 'self' data:")
	if err := t.Execute(w, s.legalData()); err != nil {
		slog.Error("página legal", "err", err)
	}
}

const legalHead = `<!doctype html><html lang="es"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
:root{--navy:#002D62;--red:#CE1126;--ink:#14243a;--muted:#55657a;--bg:#f4f7fb;--card:#fff;--line:#e3e9f1}
@media (prefers-color-scheme:dark){:root{--ink:#e8eef6;--muted:#a3b2c4;--bg:#0b1522;--card:#122133;--line:#20324a;--navy:#8db8ff}}
body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.6 -apple-system,system-ui,"Segoe UI",sans-serif}
main{max-width:720px;margin:0 auto;padding:28px 18px 60px}
header{display:flex;align-items:center;gap:10px;margin-bottom:18px}
header b{font:800 22px/1 system-ui;color:var(--navy)} header span{color:var(--red);font-weight:800}
h1{font-size:28px;line-height:1.15;margin:8px 0 4px} h2{font-size:19px;margin:30px 0 6px}
.muted{color:var(--muted);font-size:14px} section{background:var(--card);border:1px solid var(--line);border-radius:16px;padding:6px 20px 16px;margin-top:14px}
li{margin:4px 0} a{color:var(--navy)} code{background:var(--bg);padding:1px 6px;border-radius:6px}
</style>`

var privacyTmpl = template.Must(template.New("p").Parse(legalHead + `<title>Política de privacidad · KLK messenger</title></head><body><main>
<header><b>¡KLK!</b> <span>messenger</span></header>
<h1>Política de privacidad</h1>
<p class="muted">Última actualización: {{.Updated}}</p>

<section><h2>En pocas palabras</h2>
<ul>
<li>Tus mensajes, fotos, audios y llamadas van <b>cifrados de punta a punta</b>. Solo tú y la persona con quien hablas pueden verlos. KLK <b>no puede leerlos</b>.</li>
<li>Los mensajes se guardan <b>en tu móvil</b>, no en nuestros servidores. El servidor solo los guarda (cifrados) hasta que llegan al otro móvil.</li>
<li>Lo que publicas en <b>KLK Mi Gente</b> (el muro) y el perfil de tu <b>negocio</b> son <b>públicos</b> para la gente de KLK: eso no va cifrado, porque está hecho para que otros lo vean.</li>
<li>No vendemos tus datos ni ponemos publicidad.</li>
<li>Puedes <b>borrar tu cuenta</b> cuando quieras desde la app.</li>
</ul></section>

<section><h2>Quién es el responsable</h2>
<p>El responsable de tus datos es <b>{{.Owner}}</b>{{if .SupportEmail}}. Puedes escribirnos a <a href="mailto:{{.SupportEmail}}">{{.SupportEmail}}</a>{{end}}.</p></section>

<section><h2>Qué datos usamos y para qué</h2>
<ul>
<li><b>Tu número de teléfono</b>: para crear tu cuenta, enviarte el código por SMS y que tus contactos te encuentren.</li>
<li><b>Tu correo</b> (solo si entras con correo o lo añades a tu cuenta): para enviarte el código para entrar y para que puedas recuperar tu cuenta. No se le enseña a nadie.</li>
<li><b>Tu @usuario</b> (solo si eliges uno): para que te puedan escribir sin saber tu número. Lo puede buscar cualquiera que use KLK.</li>
<li><b>Claves públicas de cifrado</b>: para que otros puedan enviarte mensajes cifrados. Tus claves privadas nunca salen de tu móvil.</li>
<li><b>Mensajes y archivos cifrados en tránsito</b>: el servidor los guarda cifrados hasta que se entregan. Los archivos (fotos, vídeos, audios) se borran del servidor a los 30 días como máximo.</li>
<li><b>Tu agenda</b> (solo si das permiso): la app consulta qué números de tu agenda usan KLK. No guardamos tu agenda.</li>
<li><b>Última conexión y datos técnicos</b> (dirección IP, tipo de dispositivo): para que el servicio funcione, evitar abusos y estafas, y contar cuántas personas usan KLK.</li>
<li><b>Tu nombre y foto de perfil</b>: en los chats viajan cifrados a tus contactos y el servidor no los ve. Si usas KLK Mi Gente, tu nombre y tu foto se guardan en el servidor y salen <b>públicos</b> junto a lo que publicas o comentas.</li>
<li><b>KLK Mi Gente</b> (solo si lo usas): tus publicaciones (texto y fotos), tus comentarios, tus «me gusta», el país desde el que publicas y la fecha. Son <b>públicos</b> para cualquier persona que use KLK. También guardamos a quién bloqueas en Mi Gente (eso no se muestra a nadie) y cuándo aceptaste sus normas. Puedes borrar cada publicación o comentario cuando quieras.</li>
<li><b>Denuncias</b>: si denuncias a alguien, recibimos su número y, si tú lo eliges, los mensajes que adjuntes, para revisar el caso.</li>
<li><b>Ubicación</b> (solo si la envías en un chat): va cifrada; el servidor no la ve.</li>
<li><b>San</b>: los turnos y pagos viajan cifrados dentro del chat. Los datos de banco que pongas para cobrar se guardan solo en tu móvil y se envían cifrados únicamente a quien organiza el san; el servidor no los ve. KLK no mueve dinero.</li>
<li><b>Cuenta de negocio</b> (solo si la creas): el nombre, tipo, ciudad, horario, dirección, logo, catálogo y fotos de los productos de tu negocio son <b>públicos</b> para que los clientes te encuentren, dentro de KLK y en la página web de tu negocio que puedes compartir (por ejemplo, por WhatsApp o Instagram). Tu número de teléfono no se muestra. Los pedidos y citas viajan cifrados en el chat, como cualquier mensaje. La libreta del fiao se guarda solo en tu móvil.</li>
<li><b>Recargas de móvil</b> (cuando estén disponibles): el número a recargar, el monto y el estado del pago. Los datos de tu tarjeta los trata directamente el procesador de pagos; KLK no los ve ni los guarda.</li>
</ul></section>

<section><h2>Con quién se comparten</h2>
<p>Solo con los proveedores que necesitamos para que KLK funcione, y solo lo imprescindible:</p>
<ul>
<li>Alojamiento del servidor y la base de datos (Render).</li>
<li>Almacenamiento de archivos (Cloudflare R2): los archivos de los chats (cifrados) y las fotos públicas de Mi Gente y de los negocios.</li>
<li>Envío de los códigos por SMS (Twilio): tu número de teléfono.</li>
<li>Envío de los códigos por correo (Resend): tu correo, si entras con él o lo añades.</li>
<li>Recargas (cuando estén activas): el procesador de pagos (Stripe) y el proveedor de recargas (Reloadly).</li>
<li>Avisos (notificaciones) de Apple (iPhone) y Google Firebase Cloud Messaging (Android): el identificador de avisos de tu móvil y un aviso sin el contenido del mensaje.</li>
<li>Llamadas: si los dos móviles no pueden conectarse directamente, la llamada pasa por un servidor «puente» (Twilio o Cloudflare). La voz y el vídeo siguen cifrados de punta a punta; el puente no puede oírlos ni verlos.</li>
</ul>
<p>No damos datos a nadie más, salvo que una ley nos obligue.</p></section>

<section><h2>Cuánto tiempo los guardamos</h2>
<ul>
<li>Mensajes en el servidor: hasta que se entregan.</li>
<li>Archivos de los chats en el servidor: 30 días como máximo (1 año con KLK Plus).</li>
<li>Publicaciones, comentarios y fotos de Mi Gente, y el perfil y las fotos de tu negocio: hasta que los borras, dejas de ser negocio o borras tu cuenta. Si se borran por incumplir las normas, también desaparecen.</li>
<li>Tu cuenta: hasta que la borras. Al borrarla se eliminan del servidor tu número, tus claves, tus mensajes pendientes, tus denuncias, tus comunidades, tus recargas, tu negocio y todo lo que publicaste en Mi Gente (publicaciones, fotos, comentarios y «me gusta»).</li>
<li>Si una cuenta se bloquea por estafa o acoso, podemos guardar el número bloqueado para que no vuelva a registrarse.</li>
</ul></section>

<section><h2>Tus derechos</h2>
<p>Puedes pedir ver, corregir o borrar tus datos, oponerte a su uso o llevártelos a otro servicio. La forma más rápida de borrarlo todo es en la app: <b>Ajustes → Cuenta → Eliminar mi cuenta</b>.{{if .SupportEmail}} Para lo demás, escríbenos a <a href="mailto:{{.SupportEmail}}">{{.SupportEmail}}</a>.{{end}} Si no estás conforme, puedes reclamar ante la autoridad de protección de datos de tu país (en España, la AEPD).</p></section>

<section><h2>Menores</h2>
<p>KLK no está pensada para menores de 13 años (o la edad mínima de tu país).</p></section>

<section><h2>Cambios</h2>
<p>Si cambiamos esta política, lo avisaremos en la app.</p></section>
</main></body></html>`))

var supportTmpl = template.Must(template.New("s").Parse(legalHead + `<title>Ayuda · KLK messenger</title></head><body><main>
<header><b>¡KLK!</b> <span>messenger</span></header>
<h1>Ayuda y soporte</h1>
<section><h2>Contacto</h2>
{{if .SupportEmail}}<p>Escríbenos a <a href="mailto:{{.SupportEmail}}">{{.SupportEmail}}</a> y te contestamos lo antes posible.</p>
{{else}}<p>Escríbenos desde la app: <b>Ajustes → Ayuda</b>.</p>{{end}}</section>
<section><h2>Preguntas frecuentes</h2>
<p><b>No me llega el código por SMS.</b> Revisa que el número tenga el prefijo del país (por ejemplo +1 809… o +34…). Espera un minuto y pide otro código.</p>
<p><b>Cambié de móvil.</b> Instala KLK en el nuevo y entra con tu mismo número. Si pusiste un PIN de seguridad, te lo pedirá.</p>
<p><b>¿Quién puede leer mis mensajes?</b> Solo tú y la persona con quien hablas. Van cifrados de punta a punta.</p>
<p><b>¿Cómo denuncio a alguien?</b> Abre el chat, toca su nombre y elige <b>Denunciar</b>.</p>
<p><b>¿Cómo borro mi cuenta?</b> En la app: <b>Ajustes → Cuenta → Eliminar mi cuenta</b>. Se borra todo del servidor y de tu móvil.</p>
</section>
<p class="muted"><a href="/privacidad">Política de privacidad</a></p>
</main></body></html>`))

// Google Play pide una página web para pedir el borrado de la cuenta sin la app.
var deleteTmpl = template.Must(template.New("d").Parse(legalHead + `<title>Eliminar tu cuenta · KLK messenger</title></head><body><main>
<header><b>¡KLK!</b> <span>messenger</span></header>
<h1>Eliminar tu cuenta de KLK messenger</h1>
<section><h2>Desde la app (al momento)</h2>
<ol>
<li>Abre KLK messenger.</li>
<li>Ve a <b>Ajustes</b> (pestaña <b>Tú</b>) → <b>Eliminar mi cuenta</b>, al final.</li>
<li>Confirma. La cuenta se borra en ese mismo momento.</li>
</ol></section>
<section><h2>Sin la app</h2>
{{if .SupportEmail}}<p>Escríbenos a <a href="mailto:{{.SupportEmail}}?subject=Eliminar%20mi%20cuenta">{{.SupportEmail}}</a> con el asunto «Eliminar mi cuenta» desde el correo de tu cuenta, o indicando tu número de teléfono. Te pediremos confirmarlo y la borraremos en un máximo de 30 días (normalmente en 1 o 2 días).</p>
{{else}}<p>Instala KLK de nuevo, entra con tu número y sigue los pasos de arriba.</p>{{end}}</section>
<section><h2>Qué se borra</h2>
<ul>
<li>Tu cuenta, tu perfil, tu @usuario y tu correo.</li>
<li>Tus publicaciones, comentarios y fotos de KLK Mi Gente, y tu perfil de negocio con sus fotos.</li>
<li>Los mensajes que aún no se hubieran entregado y tus claves de cifrado del servidor.</li>
<li>Tus chats ya estaban solo en tu móvil: se borran al borrar la app.</li>
</ul>
<p>Solo guardamos, si la hubo, la denuncia o el bloqueo de un número por incumplir las <a href="/normas">normas</a>, para que no se pueda volver a usar KLK para lo mismo.</p></section>
<p class="muted"><a href="/privacidad">Política de privacidad</a> · <a href="/soporte">Ayuda</a></p>
</main></body></html>`))

var termsTmpl = template.Must(template.New("t").Parse(legalHead + `<title>Normas de uso · KLK messenger</title></head><body><main>
<header><b>¡KLK!</b> <span>messenger</span></header>
<h1>Normas de uso</h1>
<p class="muted">Última actualización: {{.Updated}}. Al crear tu cuenta aceptas estas normas y la <a href="/privacidad">política de privacidad</a>.</p>

<section><h2>Tolerancia cero</h2>
<p>En KLK <b>no se permite</b>, en chats, grupos, comunidades, estados, perfiles, KLK Mi Gente ni negocios:</p>
<ul>
<li>Acoso, amenazas, intimidación o insultos a una persona o grupo.</li>
<li>Odio o discriminación por origen, raza, religión, sexo, orientación, discapacidad u otra condición.</li>
<li>Violencia gráfica, terrorismo o incitación a hacer daño.</li>
<li>Contenido sexual explícito y, en ningún caso, nada que sexualice a menores.</li>
<li>Estafas, fraudes, suplantar a otra persona, spam o cadenas.</li>
<li>Vender o promover drogas, armas u otras cosas ilegales.</li>
<li>Compartir datos o fotos privadas de otra persona sin su permiso.</li>
</ul>
<p>Lo público (KLK Mi Gente, negocios, nombres y @usuario) pasa por un <b>filtro automático</b>: si lleva insultos graves, odio o contenido sexual explícito, no se publica.</p>
<p>Quien incumpla estas normas puede ser <b>expulsado de las comunidades y bloqueado en KLK</b>, sin aviso.</p></section>

<section><h2>Cómo denunciar y bloquear</h2>
<ul>
<li><b>Un mensaje</b>: mantenlo pulsado y elige <b>Denunciar</b>.</li>
<li><b>Una persona</b>: toca su nombre (en un chat, grupo o comunidad) y elige <b>Denunciar</b> o <b>Bloquear</b>. Al bloquearla dejas de recibir sus mensajes.</li>
<li><b>En KLK Mi Gente</b>: toca <b>⋯</b> en una publicación (o mantén pulsado un comentario) y elige <b>Denunciar</b> o <b>Bloquear</b>. Si bloqueas a alguien, no verás lo suyo, no verá lo tuyo y no podrá comentar ni dar «me gusta» a tus publicaciones.</li>
</ul>
<p>Cuando bloqueas a alguien, lo suyo desaparece al momento de tu pantalla y el equipo de KLK recibe un aviso para revisarlo.</p>
<p>Revisamos las denuncias y los bloqueos en <b>24 horas</b> como máximo: borramos el contenido que incumple las normas y expulsamos de KLK a quien lo publicó.{{if .SupportEmail}} También puedes escribirnos a <a href="mailto:{{.SupportEmail}}">{{.SupportEmail}}</a>.{{end}}</p></section>

<section><h2>KLK Mi Gente</h2>
<p>Mi Gente es el muro público de KLK: lo que publicas y comentas lo puede ver cualquiera que use KLK. Antes de publicar por primera vez tienes que aceptar estas normas. Publica solo fotos tuyas o con permiso, y nada de datos personales de otros. Borramos lo que incumpla las normas y podemos bloquear la cuenta.</p></section>

<section><h2>Vender en Mi Gente</h2>
<p>Puedes publicar cosas tuyas a la venta con su precio. Solo se permiten cosas legales y que sean tuyas: <b>nada de armas, drogas, medicinas, alcohol, tabaco, animales, cosas robadas o falsificadas, ni servicios ilegales</b>. El trato (precio, pago y entrega) es entre quien vende y quien compra: <b>KLK no cobra, no hace envíos y no es parte de la venta</b>. Consejo: queda en un sitio público, mira el producto antes de pagar y no pagues por adelantado.</p></section>

<section><h2>Negocios</h2>
<p>Si pones tu negocio en KLK, la información y los precios que publicas deben ser reales y eres responsable de lo que vendes. Los pedidos y citas son un acuerdo entre el negocio y el cliente: <b>KLK no cobra, no entrega y no es parte de ese acuerdo</b>.</p></section>

<section><h2>Comunidades</h2>
<p>Las comunidades por país son abiertas a los dominicanos de ese país. Trata a todos con respeto; tu número de teléfono no se muestra a los demás miembros.</p></section>

<section><h2>El san</h2>
<p>KLK solo ayuda a llevar la cuenta del san (turnos, quién pagó, recordatorios). <b>KLK no recibe, guarda ni envía dinero</b> y no es parte del acuerdo entre los participantes, que es responsabilidad de ellos.</p></section>

<section><h2>Edad mínima</h2>
<p>Necesitas tener al menos 13 años (o la edad mínima de tu país) para usar KLK.</p></section>

<section><h2>Cambios</h2>
<p>Si cambiamos estas normas, lo avisaremos en la app.</p></section>
</main></body></html>`))
