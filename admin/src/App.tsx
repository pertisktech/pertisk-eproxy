import { Routes, Route } from 'react-router-dom';
import Layout from './components/Layout';
import Dashboard from './routes/Dashboard';
import Sites from './routes/Sites';
import SiteDetail from './routes/SiteDetail';
import Certificates from './routes/Certificates';
import DnsProviders from './routes/DnsProviders';
import Backends from './routes/Backends';
import Metrics from './routes/Metrics';
import Settings from './routes/Settings';

export default function App() {
  return (
    <Routes>
      <Route element={<Layout />}>
        <Route path="/" element={<Dashboard />} />
        <Route path="/sites" element={<Sites />} />
        <Route path="/sites/:host" element={<SiteDetail />} />
        <Route path="/certificates" element={<Certificates />} />
        <Route path="/dns-providers" element={<DnsProviders />} />
        <Route path="/backends" element={<Backends />} />
        <Route path="/metrics" element={<Metrics />} />
        <Route path="/settings" element={<Settings />} />
        <Route path="*" element={<Dashboard />} />
      </Route>
    </Routes>
  );
}
