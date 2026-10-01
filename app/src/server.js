import express from 'express';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadUser, requireLogin, checkCsrf } from './auth.js';
import { viewHelpers } from './helpers.js';
import authRoutes from './routes/auth.js';
import homeRoutes from './routes/home.js';
import leadRoutes from './routes/leads.js';
import customerRoutes from './routes/customers.js';
import salesRoutes from './routes/sales.js';
import campaignRoutes from './routes/campaigns.js';
import reportRoutes from './routes/reports.js';
import adminRoutes from './routes/admin.js';
import aiRoutes from './routes/ai.js';

const here = path.dirname(fileURLToPath(import.meta.url));

export function createApp() {
    const app = express();
    app.set('view engine', 'ejs');
    app.set('views', path.join(here, 'views'));
    app.set('trust proxy', 1);
    app.disable('x-powered-by');

    app.use((req, res, next) => {
        res.setHeader('X-Frame-Options', 'DENY');
        res.setHeader('X-Content-Type-Options', 'nosniff');
        res.setHeader('Referrer-Policy', 'same-origin');
        res.setHeader('Content-Security-Policy',
            "default-src 'self'; style-src 'self'; script-src 'self'; img-src 'self' data:; form-action 'self'; frame-ancestors 'none'");
        next();
    });
    app.use('/static', express.static(path.join(here, 'public'), { maxAge: '1h' }));
    app.use(express.urlencoded({ extended: false, limit: '5mb' }));
    app.use(viewHelpers);
    app.use(loadUser);
    app.use(checkCsrf);

    app.get('/healthz', (req, res) => res.type('text').send('ok'));
    app.use(authRoutes);
    app.use(requireLogin);
    app.use(homeRoutes);
    app.use('/leads', leadRoutes);
    app.use('/customers', customerRoutes);
    app.use(salesRoutes);
    app.use('/campaigns', campaignRoutes);
    app.use('/reports', reportRoutes);
    app.use('/admin', adminRoutes);
    app.use('/ai', aiRoutes);

    app.use((req, res) => res.status(404).render('error', { title: 'Not found', message: 'This page does not exist, or you do not have access to it.' }));
    app.use((err, req, res, next) => {
        console.error(err);
        res.status(500).render('error', { title: 'Something went wrong', message: 'The error has been logged. Please try again.' });
    });
    return app;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
    const port = Number(process.env.PORT || 3000);
    createApp().listen(port, () => console.log(`CRM listening on http://localhost:${port}`));
}
