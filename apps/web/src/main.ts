import { isDevMode } from '@angular/core';
import { bootstrapApplication } from '@angular/platform-browser';
import { provideHttpClient } from '@angular/common/http';
import { provideIonicAngular } from '@ionic/angular';
import { addIcons } from 'ionicons';
import {
  addOutline,
  arrowBackOutline,
  arrowForwardOutline,
  bookmark,
  bookmarkOutline,
  chatbubbleOutline,
  checkmarkOutline,
  closeOutline,
  earthOutline,
  ellipsisHorizontal,
  heart,
  heartOutline,
  homeOutline,
  informationCircleOutline,
  lockClosedOutline,
  newspaperOutline,
  optionsOutline,
  peopleOutline,
  personOutline,
  playCircleOutline,
  searchOutline,
  sendOutline,
  shareOutline,
  stopCircleOutline,
  videocamOutline,
} from 'ionicons/icons';
import { AppComponent } from './app/app.component';

addIcons({
  addOutline,
  arrowBackOutline,
  arrowForwardOutline,
  bookmark,
  bookmarkOutline,
  chatbubbleOutline,
  checkmarkOutline,
  closeOutline,
  earthOutline,
  ellipsisHorizontal,
  heart,
  heartOutline,
  homeOutline,
  informationCircleOutline,
  lockClosedOutline,
  newspaperOutline,
  optionsOutline,
  peopleOutline,
  personOutline,
  playCircleOutline,
  searchOutline,
  sendOutline,
  shareOutline,
  stopCircleOutline,
  videocamOutline,
});

bootstrapApplication(AppComponent, {
  providers: [provideIonicAngular(), provideHttpClient()],
}).catch((error: unknown) => console.error(error));

if (!isDevMode() && 'serviceWorker' in navigator) {
  window.addEventListener('load', () => {
    void navigator.serviceWorker.register('sw.js').catch(() => undefined);
  });
}
