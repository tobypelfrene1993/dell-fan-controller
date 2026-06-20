# Publish Checklist

1. Review all files in this export.
2. Choose a final license and add `LICENSE`.
3. Confirm `SANITIZATION_REPORT.md` status is PASS.
4. Confirm no `controller-config.production.json`, logs, state files or binaries exist.
5. Initialize Git in this public export only:

```powershell
Set-Location 'C:\DellFanController-public'
git init
git add .
git commit -m "Initial public release"
```

6. Create a new public GitHub repository manually.
7. Add the remote manually:

```powershell
git remote add origin https://github.com/<owner>/<repo>.git
git branch -M main
git push -u origin main
```

Do not run these steps from the protected production source folder.
