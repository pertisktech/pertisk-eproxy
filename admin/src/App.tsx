import { Routes, Route } from 'react-router-dom';
import Layout from '@/components/Layout';
import Dashboard from '@/routes/Dashboard';
import Metrics from '@/routes/Metrics';
import Logs from '@/routes/Logs';
import Sites from '@/routes/Sites';
import SiteDetail from '@/routes/SiteDetail';
import Certificates from '@/routes/Certificates';
import DnsProviders from '@/routes/DnsProviders';
import Helm from '@/routes/Helm';
import Profile from '@/routes/Profile';
import Settings from '@/routes/Settings';
import Docs from '@/routes/Docs';
import Backup from '@/routes/Backup';
import Login from '@/routes/Login';
import NotFound from '@/routes/NotFound';

export default function App() {
  return (
    <Routes>
      <Route path="/login" element={<Login />} />
      <Route element={<Layout />}>
        <Route path="/" element={<Dashboard />} />
        <Route path="/metrics" element={<Metrics />} />
        <Route path="/logs" element={<Logs />} />
        <Route path="/sites" element={<Sites />} />
        <Route path="/sites/:host" element={<SiteDetail />} />
        <Route path="/certificates" element={<Certificates />} />
        <Route path="/dns-providers" element={<DnsProviders />} />
        <Route path="/helm" element={<Helm />} />
        <Route path="/profile" element={<Profile />} />
        <Route path="/settings" element={<Settings />} />
        <Route path="/docs" element={<Docs />} />
        <Route path="/backup" element={<Backup />} />
        <Route path="*" element={<NotFound />} />
      </Route>
    </Routes>
  );
}
