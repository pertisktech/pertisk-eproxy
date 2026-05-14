# Pertisk eProxy Admin UI

Modern React-based admin dashboard for managing the Pertisk eProxy reverse proxy.

## Features

- **Dashboard**: System overview and real-time statistics
- **Sites Management**: Add, view, and remove reverse proxy upstreams
- **Certificate Management**: Manage SSL/TLS certificates and ACME automation
- **Settings**: Configure proxy parameters, ACME provider, and compression

## Getting Started

### Prerequisites

- Node.js 16+ and npm

### Installation

```bash
npm install
```

### Development

Start the development server:

```bash
npm start
```

The application will open at `http://localhost:3000`.

**Note:** The proxy server must be running on `http://localhost:8080` for the API calls to work.

### Building for Production

```bash
npm run build
```

This creates an optimized production build in the `build` directory.

## Project Structure

```
admin-ui/
├── public/
│   └── index.html          # HTML template
├── src/
│   ├── api/
│   │   └── client.js       # API client with axios
│   ├── components/
│   │   └── Layout.js       # Main layout with navigation
│   ├── pages/
│   │   ├── Dashboard.js    # Overview and stats
│   │   ├── Sites.js        # Manage upstreams
│   │   ├── Certificates.js # Manage TLS certs
│   │   └── Settings.js     # Configuration
│   ├── App.js              # Main app with routing
│   ├── index.js            # React entry point
│   └── index.css           # Tailwind CSS styles
├── package.json
├── tailwind.config.js      # Tailwind configuration
└── postcss.config.js       # PostCSS configuration
```

## API Integration

The admin UI communicates with the Erlang backend via REST API:

### Available Endpoints

- `GET /api/status` - System status
- `GET /api/upstreams` - List upstreams
- `POST /api/upstreams` - Add upstream
- `DELETE /api/upstreams/:host` - Remove upstream
- `GET /api/certs` - Certificate info
- `POST /api/certs/request` - Request certificate

## Configuration

Set the API endpoint via environment variable:

```bash
REACT_APP_API_URL=http://localhost:8080/api npm start
```

Default: `http://localhost:8080/api`

## Technologies

- **React 18** - UI framework
- **React Router v6** - Navigation
- **Axios** - HTTP client
- **Tailwind CSS** - Styling
- **Lucide Icons** - Icons

## Development

### Adding New Pages

1. Create a new component in `src/pages/`
2. Add route in `App.js`
3. Add navigation link in `Layout.js`

### Styling

Uses Tailwind CSS. Customize in `tailwind.config.js`.

### API Calls

Add new methods in `src/api/client.js`:

```javascript
export const newEndpoint = async (data) => {
  try {
    const response = await api.post('/endpoint', data);
    return response.data;
  } catch (error) {
    console.error('Error:', error);
    throw error;
  }
};
```

## Testing

```bash
npm test
```

## Deployment

The build output should be served by a web server (e.g., nginx):

```nginx
server {
    listen 80;
    location / {
        root /path/to/build;
        try_files $uri $uri/ /index.html;
    }
    location /api {
        proxy_pass http://localhost:8080/api;
    }
}
```

## License

Proprietary - Pertisk Technologies

## Support

For issues and questions, contact: support@pertisk.tech
