import React, { useState } from 'react';
import { Outlet, Link, useLocation } from 'react-router-dom';
import { Menu, X, Server, Globe, Shield, Settings } from 'lucide-react';

function Layout() {
  const [isOpen, setIsOpen] = useState(false);
  const location = useLocation();

  const isActive = (path) => location.pathname === path ? 'bg-blue-600 text-white' : 'text-gray-700 hover:bg-gray-100';

  const navItems = [
    { path: '/', label: 'Dashboard', icon: Server },
    { path: '/sites', label: 'Sites', icon: Globe },
    { path: '/certificates', label: 'Certificates', icon: Shield },
    { path: '/settings', label: 'Settings', icon: Settings },
  ];

  return (
    <div className="flex h-screen bg-gray-50">
      {/* Mobile menu button */}
      <button
        onClick={() => setIsOpen(!isOpen)}
        className="md:hidden fixed top-4 left-4 z-50 p-2 rounded-lg bg-white shadow-lg"
      >
        {isOpen ? <X size={24} /> : <Menu size={24} />}
      </button>

      {/* Sidebar */}
      <aside
        className={`${
          isOpen ? 'block' : 'hidden'
        } md:block w-64 bg-white shadow-lg fixed md:static h-full z-40`}
      >
        <div className="p-6 border-b">
          <h1 className="text-2xl font-bold text-blue-600">eProxy</h1>
          <p className="text-sm text-gray-500 mt-1">Reverse Proxy Manager</p>
        </div>

        <nav className="flex-1 px-4 py-6">
          {navItems.map(({ path, label, icon: Icon }) => (
            <Link
              key={path}
              to={path}
              onClick={() => setIsOpen(false)}
              className={`flex items-center gap-3 px-4 py-3 rounded-lg mb-2 transition ${isActive(path)}`}
            >
              <Icon size={20} />
              <span>{label}</span>
            </Link>
          ))}
        </nav>

        <div className="p-4 border-t text-xs text-gray-500">
          <p>Pertisk eProxy v0.1.0</p>
        </div>
      </aside>

      {/* Main content */}
      <div className="flex-1 flex flex-col md:ml-0">
        <header className="bg-white border-b h-16 flex items-center px-6 shadow-sm">
          <h2 className="text-xl font-semibold text-gray-800">Management Console</h2>
        </header>

        <main className="flex-1 overflow-auto p-6">
          <Outlet />
        </main>
      </div>
    </div>
  );
}

export default Layout;
