const fastify = require('fastify');
const fastifyCookie = require('@fastify/cookie');
const fastifyMultipart = require('@fastify/multipart');
const fastifyCors = require('@fastify/cors');
const { pathCase } = require('change-case');
const NeteaseCloudMusicApi = require('@neteasecloudmusicapienhanced/api');

const initAppServer = async () => {
  try {
    const server = fastify({
      routerOptions: {
        ignoreTrailingSlash: true,
      },
    });

    server.register(fastifyCors, {
      origin: '*',
      credentials: true,
    });
    server.register(fastifyCookie);
    server.register(fastifyMultipart);

    server.get('/api', (_, reply) => {
      reply.send({
        name: 'SPlayer NodeJS Mobile Backend',
      });
    });

    server.get('/api/netease', (_, reply) => {
      reply.send({
        name: '@neteaseapireborn/api',
        description: '网易云音乐 API Enhanced (Mobile)',
      });
    });

    const dynamicHandler = async (req, reply) => {
      const requestPath = req.params['*'];
      const routerName = Object.keys(NeteaseCloudMusicApi).find((key) => {
        if (typeof NeteaseCloudMusicApi[key] !== 'function') return false;
        return pathCase(key) === requestPath || key === requestPath;
      });

      if (!routerName) {
        return reply.status(404).send({ error: 'API not found' });
      }

      const neteaseApi = NeteaseCloudMusicApi[routerName];
      console.log('🌐 Request NcmAPI:', requestPath);

      try {
        const result = await neteaseApi({
          ...req.query,
          ...req.body,
          cookie: req.cookies,
        });
        return reply.send(result.body);
      } catch (error) {
        console.error('❌ NcmAPI Error:', error);
        if (typeof error === 'object' && error) {
          if ([400, 301].includes(error.status)) {
            return reply.status(error.status).send(error.body);
          }
          return reply
            .status(500)
            .send(error.body || { error: error.message || 'Internal Server Error' });
        }
        return reply.status(500).send({ error: String(error) });
      }
    };

    server.get('/api/netease/*', dynamicHandler);
    server.post('/api/netease/*', dynamicHandler);

    // Run on specific port
    const port = 25884;
    await server.listen({ port, host: '127.0.0.1' });
    console.log(`🌐 Starting Mobile AppServer on port ${port}`);
    return server;
  } catch (error) {
    console.error('🚫 Mobile AppServer failed to start');
    throw error;
  }
};

initAppServer();
